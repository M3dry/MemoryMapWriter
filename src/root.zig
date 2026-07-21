const std = @import("std");
pub const MemoryMapWriter = struct {
    io: std.Io,
    file: std.Io.File,
    mm: std.Io.File.MemoryMap,
    writer: std.Io.Writer,

    const vtable = std.Io.Writer.VTable{
        .drain = drain,
        .flush = flush,
        .sendFile = sendFile,
        .rebase = rebase,
    };

    pub fn init(io: std.Io, file: std.Io.File, initial_size: usize) !MemoryMapWriter {
        try file.setLength(io, initial_size);
        const mm = try file.createMemoryMap(io, .{ .len = initial_size });
        return .{
            .io = io,
            .file = file,
            .mm = mm,
            .writer = .{
                .vtable = &vtable,
                .buffer = mm.memory,
                .end = 0,
            },
        };
    }

    pub fn deinit(self: *MemoryMapWriter) void {
        self.mm.write(self.io) catch {};
        self.file.setLength(self.io, self.writer.end) catch {};
        self.mm.destroy(self.io);
    }

    pub fn written(self: *const MemoryMapWriter) []const u8 {
        return self.mm.memory[0..self.writer.end];
    }

    pub fn seekTo(self: *MemoryMapWriter, pos: usize) error{SeekBeyondBufferEnd}!void {
        if (pos > self.writer.buffer.len) return error.SeekBeyondBufferEnd;
        self.writer.end = pos;
    }

    pub fn ensureUnusedCapacity(self: *MemoryMapWriter, n: usize) std.Io.Writer.Error!void {
        if (self.writer.buffer.len - self.writer.end < n)
            try self.grow(n);
    }

    /// syncs buffer to file, and resizes file to buffer length
    pub fn truncate(self: *MemoryMapWriter) std.Io.Writer.Error!void {
        try self.writer.flush();
        self.file.setLength(self.io, self.writer.end) catch return error.WriteFailed;
    }

    fn grow(self: *MemoryMapWriter, min_extra: usize) std.Io.Writer.Error!void {
        self.mm.write(self.io) catch return error.WriteFailed;
        const curr_len = self.mm.memory.len;
        const needed = self.writer.end + min_extra;
        const new_len = @max(needed, curr_len * 2);
        self.mm.destroy(self.io);
        self.file.setLength(self.io, new_len) catch return error.WriteFailed;
        self.mm = self.file.createMemoryMap(self.io, .{ .len = new_len }) catch return error.WriteFailed;
        self.writer.buffer = self.mm.memory;
    }

    fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *MemoryMapWriter = @fieldParentPtr("writer", io_w);

        const data_total = blk: {
            var total: usize = 0;
            for (data[0 .. data.len - 1]) |s| total += s.len;
            total += data[data.len - 1].len * splat;
            break :blk total;
        };

        if (io_w.buffer.len - io_w.end < data_total)
            try self.grow(data_total);

        for (data[0 .. data.len - 1]) |s| {
            @memcpy(io_w.buffer[io_w.end..][0..s.len], s);
            io_w.end += s.len;
        }
        if (data[data.len - 1].len > 0) {
            for (0..splat) |_| {
                const p = data[data.len - 1];
                @memcpy(io_w.buffer[io_w.end..][0..p.len], p);
                io_w.end += p.len;
            }
        }

        return data_total;
    }

    fn sendFile(io_w: *std.Io.Writer, file_reader: *std.Io.File.Reader, limit: std.Io.Limit) std.Io.Writer.FileError!usize {
        if (file_reader.interface.bufferedLen() > 0)
            return error.Unimplemented;

        const self: *MemoryMapWriter = @fieldParentPtr("writer", io_w);

        if (io_w.buffer.len - io_w.end == 0)
            try self.grow(limit.toInt() orelse 1);

        const dest = limit.slice(io_w.buffer[io_w.end..]);
        const n = file_reader.file.readPositional(self.io, &.{dest}, file_reader.pos) catch |err| switch (err) {
            error.Unseekable => return error.Unimplemented,
            error.Canceled => return error.WriteFailed,
            else => return error.ReadFailed,
        };

        if (n == 0) return error.EndOfStream;

        file_reader.pos += n;
        io_w.end += n;

        return n;
    }

    fn flush(io_w: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *MemoryMapWriter = @fieldParentPtr("writer", io_w);
        self.mm.write(self.io) catch return error.WriteFailed;
    }

    fn rebase(io_w: *std.Io.Writer, preserve: usize, capacity: usize) std.Io.Writer.Error!void {
        _ = preserve;
        if (io_w.buffer.len - io_w.end >= capacity) return;
        const self: *MemoryMapWriter = @fieldParentPtr("writer", io_w);
        try self.grow(capacity);
    }
};

test "MemoryMapWriter: sendFile copies file into mmap" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const src_file = try tmp.dir.createFile(io, "src.bin", .{ .read = true });
    defer src_file.close(io);
    try src_file.setLength(io, 100);

    var src_mm = try src_file.createMemoryMap(io, .{ .len = 100 });
    defer src_mm.destroy(io);
    @memset(src_mm.memory[0..100], 0xAB);

    const dst_file = try tmp.dir.createFile(io, "dst.bin", .{ .read = true });
    defer dst_file.close(io);

    var mmw = try MemoryMapWriter.init(io, dst_file, 32);
    try mmw.writer.writeAll("HEADER:");
    {
        var src_reader = std.Io.File.Reader.init(src_file, io, &.{});
        const n = try mmw.writer.sendFileAll(&src_reader, .limited(90));
        try std.testing.expectEqual(@as(usize, 90), n);
    }
    try mmw.writer.writeAll(":FOOTER");
    mmw.deinit();

    const data = try tmp.dir.readFileAlloc(io, "dst.bin", allocator, .unlimited);
    defer allocator.free(data);

    try std.testing.expectEqualStrings("HEADER:", data[0..7]);
    for (data[7..97]) |b| try std.testing.expectEqual(@as(u8, 0xAB), b);
    try std.testing.expectEqualStrings(":FOOTER", data[97..104]);
    try std.testing.expectEqual(@as(usize, 104), data.len);
}

test "MemoryMapWriter: written, seekTo, ensureUnusedCapacity, truncate" {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file = try tmp.dir.createFile(io, "test.bin", .{ .read = true });
    defer file.close(io);

    var mmw = try MemoryMapWriter.init(io, file, 64);
    defer mmw.deinit();

    try mmw.writer.writeAll("Hello, World!");
    try std.testing.expectEqualStrings("Hello, World!", mmw.written());

    try mmw.ensureUnusedCapacity(128);
    try std.testing.expect(mmw.writer.buffer.len - mmw.writer.end >= 128);

    try mmw.writer.print(" answer is {d}", .{42});
    try std.testing.expectEqualStrings("Hello, World! answer is 42", mmw.written());

    try mmw.seekTo(5);
    try mmw.writer.writeAll(" there");
    try std.testing.expectEqualStrings("Hello there", mmw.written());

    try mmw.truncate();
    const verify = try tmp.dir.readFileAlloc(io, "test.bin", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(verify);
    try std.testing.expectEqualStrings("Hello there", verify);
}

test "MemoryMapWriter: basic write, growth, and readback" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const file = try tmp.dir.createFile(io, "test.bin", .{ .read = true });
    defer file.close(io);

    var mmw = try MemoryMapWriter.init(io, file, 8);
    try mmw.writer.writeAll("Hello, World!");
    try mmw.writer.print(" answer is {d}", .{42});
    mmw.deinit();

    const data = try tmp.dir.readFileAlloc(io, "test.bin", allocator, .unlimited);
    defer allocator.free(data);
    try std.testing.expectEqualStrings("Hello, World! answer is 42", data);
}
