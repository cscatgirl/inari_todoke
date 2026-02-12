const std = @import("std");
const os = std.os;
const posix = std.posix;
pub const Config = struct {
    device_id: []u8,
    alias: []const u8,
    listen_port: u16,
    download_dir: []const u8,

    fn expandTilde(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (path.len >= 1 and path[0] == '~') {
            const home = posix.getenv("HOME") orelse return error.HomeNotSet;
            if (path.len == 1) return try alloc.dupe(u8, home);
            return try std.fs.path.join(alloc, &.{ home, path[2..] });
        }
        return try alloc.dupe(u8, path);
    }
    fn create_file(dir: std.fs.Dir, alloc: std.mem.Allocator) !Config {
        const file: std.fs.File = try dir.createFile("config.json", .{});
        defer file.close();
        var host_name_buff: [posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try posix.gethostname(&host_name_buff);
        var writer = std.io.Writer.Allocating.init(alloc);
        const download_dir = try expandTilde(alloc, "~/Downloads");
        const config_to_write = Config{ .device_id = try generateUuidV4(alloc), .alias = hostname, .listen_port = 53318, .download_dir = download_dir };
        try std.json.Stringify.value(config_to_write, .{}, &writer.writer);
        try file.writeAll(try writer.toOwnedSlice());
        defer writer.deinit();
        return config_to_write;
    }
    pub fn generateUuidV4(allocator: std.mem.Allocator) ![]u8 {
        var bytes: [16]u8 = undefined;
        std.crypto.random.bytes(&bytes);

        // Set version (4) and variant bits according to RFC 4122
        bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4
        bytes[8] = (bytes[8] & 0x3f) | 0x80; // Variant 10xx
        // Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            bytes[0],  bytes[1],  bytes[2],  bytes[3],
            bytes[4],  bytes[5],  bytes[6],  bytes[7],
            bytes[8],  bytes[9],  bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15],
        });
    }
    pub fn load(alloc: std.mem.Allocator) !Config {
        const dir_name = try std.fs.getAppDataDir(alloc, "inari_todoke");
        const dir: std.fs.Dir = blk: {
            break :blk std.fs.openDirAbsolute(dir_name, .{}) catch |err| {
                if (err == std.fs.Dir.AccessError.FileNotFound) {
                    try std.fs.makeDirAbsolute(dir_name);
                    break :blk try std.fs.openDirAbsolute(dir_name, .{});
                } else {
                    return err;
                }
            };
        };
        const file = dir.openFile("config.json", .{ .mode = .read_write }) catch |err|
            {
                if (err == std.fs.File.OpenError.FileNotFound) {
                    return create_file(dir, alloc);
                } else {
                    return err;
                }
            };
        const stat = try file.stat();
        const buffer = try file.readToEndAlloc(alloc, stat.size);
        defer alloc.free(buffer);
        const data = try std.json.parseFromSlice(Config, alloc, buffer, .{ .allocate = .alloc_always });
        const val: Config = data.value;
        const return_config = Config{ .device_id = try alloc.dupe(u8, val.device_id), .alias = try alloc.dupe(u8, val.alias), .listen_port = val.listen_port, .download_dir = try expandTilde(alloc, val.download_dir) };
        defer data.deinit();
        return return_config;
    }
};
