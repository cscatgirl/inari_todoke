const std = @import("std");
const testing = std.testing;
pub const FileEntry = struct { relative_path: []const u8, absolute_path: []const u8, size: u64, modified: i128 };
pub fn enumerateFiles(alloc: std.mem.Allocator, path: []const u8) ![]FileEntry {
    var dir: std.fs.Dir = blk: {
        std.debug.print("{s}", .{path});
        break :blk std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
            if (err == std.fs.File.OpenError.NotDir) {
                const file_name = std.fs.path.basename(path);
                const file = try std.fs.openFileAbsolute(path, .{});
                defer file.close();
                const size = try file.stat();
                const entry = FileEntry{ .relative_path = file_name, .absolute_path = path, .size = size.size, .modified = size.mtime };
                const result = try alloc.alloc(FileEntry, 1);
                result[0] = entry;
                return result;
            } else {
                return err;
            }
        };
    };
    defer dir.close();
    var os_walker: std.fs.Dir.Walker = try dir.walk(alloc);
    defer os_walker.deinit();
    var array_list: std.ArrayList(FileEntry) = .empty;
    while (try os_walker.next()) |entry| {
        if (entry.kind != .file) continue;
        const abs_file_path = try std.fs.path.join(alloc, &.{ path, entry.path });
        const file = try std.fs.openFileAbsolute(abs_file_path, .{});
        const stats = try file.stat();
        defer file.close();
        const sub_dir_name = std.fs.path.basename(path);
        const file_entry = FileEntry{ .absolute_path = abs_file_path, .relative_path = try std.fs.path.join(alloc, &.{ sub_dir_name, entry.path }), .size = stats.size, .modified = stats.mtime };
        try array_list.append(alloc, file_entry);
    }
    return array_list.toOwnedSlice(alloc);
}

pub fn createFileWithDirs(alloc: std.mem.Allocator, base_dir: []const u8, rel_path: []const u8) !std.fs.File {
    const full_path = try std.fs.path.join(alloc, &.{ base_dir, rel_path });
    defer alloc.free(full_path);
    if (std.fs.path.dirname(full_path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| {
            if (err != std.posix.MakeDirError.PathAlreadyExists) return err;
        };
    }
    return std.fs.createFileAbsolute(full_path, .{});
}
test "single file returns one entry" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("hello.txt", .{});
    file.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "hello.txt");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("hello.txt", entries[0].relative_path);
    try testing.expectEqualStrings(abs_path, entries[0].absolute_path);
}

test "single file reports correct size" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("data.bin", .{});
    try file.writeAll("abcdef1234567890");
    file.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "data.bin");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(u64, 16), entries[0].size);
}

test "single file in subdirectory uses basename as relative_path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("inner");
    var subdir = try tmp.dir.openDir("inner", .{});
    defer subdir.close();
    const file = try subdir.createFile("afile.txt", .{});
    file.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "inner/afile.txt");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("afile.txt", entries[0].relative_path);
}

test "directory enumerates all files inside" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("mydir");
    var dir = try tmp.dir.openDir("mydir", .{});
    defer dir.close();
    const f1 = try dir.createFile("a.txt", .{});
    f1.close();
    const f2 = try dir.createFile("b.txt", .{});
    f2.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "mydir");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.absolute_path);
            testing.allocator.free(e.relative_path);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "directory entries have correct relative paths with dir name prefix" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("stuff");
    var dir = try tmp.dir.openDir("stuff", .{});
    defer dir.close();
    const f = try dir.createFile("notes.txt", .{});
    f.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "stuff");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.absolute_path);
            testing.allocator.free(e.relative_path);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("stuff/notes.txt", entries[0].relative_path);
}

test "nested directory enumerates recursively" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("top");
    var top = try tmp.dir.openDir("top", .{});
    defer top.close();
    try top.makeDir("sub");
    var sub = try top.openDir("sub", .{});
    defer sub.close();
    const f1 = try top.createFile("root.txt", .{});
    f1.close();
    const f2 = try sub.createFile("deep.txt", .{});
    f2.close();
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "top");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer {
        for (entries) |e| {
            testing.allocator.free(e.absolute_path);
            testing.allocator.free(e.relative_path);
        }
        testing.allocator.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "empty directory returns zero entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("empty");
    const abs_path = try tmp.dir.realpathAlloc(testing.allocator, "empty");
    defer testing.allocator.free(abs_path);
    const entries = try enumerateFiles(testing.allocator, abs_path);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}
