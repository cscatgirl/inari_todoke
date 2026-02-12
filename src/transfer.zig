const std = @import("std");
const posix = std.posix;
const Config = @import("config.zig").Config;
const Protocol = @import("protocol.zig");
const fs_utils = @import("fs.zig");
const Peer = @import("peer.zig").Peer;
const FileTransferErrors = error{ ChecksumMisMatch, PathIsInvalid, TransferRejected };

fn tuneSocket(fd: posix.socket_t) void {
    // Disable Nagle's algorithm — send packets immediately
    posix.setsockopt(fd, posix.IPPROTO.TCP, std.c.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
    // 2 MB kernel send/receive buffers
    const buf_size = 2 * 1024 * 1024;
    posix.setsockopt(fd, posix.SOL.SOCKET, std.c.SO.SNDBUF, &std.mem.toBytes(@as(c_int, buf_size))) catch {};
    posix.setsockopt(fd, posix.SOL.SOCKET, std.c.SO.RCVBUF, &std.mem.toBytes(@as(c_int, buf_size))) catch {};
}
pub const Progress = struct { current_file: []const u8, files_done: usize, files_total: usize, bytes_sent: u64, bytes_total: u64 };
fn isPathSafe(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return false;
    for (path) |c| {
        if (c == 0) return false;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |comp| {
        if (std.mem.eql(u8, comp, "..")) return false;
    }
    return true;
}
pub fn startServer(alloc: std.mem.Allocator, user_config: Config, on_offer: *const fn (Protocol.TransferOfferPayload) bool, on_progress: *const fn (Progress) void) !std.Thread {
    const server = try alloc.create(std.net.Server);
    const addr = try std.net.Address.parseIp("0.0.0.0", user_config.listen_port);
    server.* = try addr.listen(.{ .reuse_address = true });
    return try std.Thread.spawn(.{}, serverLoop, .{ alloc, user_config, server, on_offer, on_progress });
}
pub fn serverLoop(alloc: std.mem.Allocator, user_config: Config, server: *std.net.Server, on_offer: *const fn (Protocol.TransferOfferPayload) bool, on_progress: *const fn (Progress) void) !void {
    defer server.deinit();
    while (true) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        handleConnection(alloc, user_config, conn.stream, on_offer, on_progress) catch return;
    }
}
fn handleConnection(alloc: std.mem.Allocator, user_config: Config, stream: std.net.Stream, on_offer: *const fn (Protocol.TransferOfferPayload) bool, on_progress: *const fn (Progress) void) !void {
    tuneSocket(stream.handle);
    var read_buf: [256 * 1024]u8 = undefined;
    var write_buf: [4096]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);
    const offer_msg = Protocol.read_message(alloc, reader.interface()) catch return;
    defer offer_msg.deinit();
    const offer = offer_msg.value.transfer_offer;
    const accepted = on_offer(offer);
    Protocol.write_message(alloc, &writer.interface, .{ .transfer_response = .{ .transfer_id = offer.transfer_id, .accepted = accepted } }) catch return;
    writer.interface.flush() catch return;
    if (!accepted) return;
    for (0..offer.total_files) |i| {
        const header_msg = Protocol.read_message(alloc, reader.interface()) catch return;
        const header = header_msg.value.file_header;
        if (!isPathSafe(header.path)) return error.PathIsInvalid;
        const out_file = fs_utils.createFileWithDirs(alloc, user_config.download_dir, header.path) catch return;
        defer out_file.close();

        var remaining: u64 = header.size;
        var checksum = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [512 * 1024]u8 = undefined;
        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, buf.len));
            const n = reader.interface().readSliceShort(buf[0..to_read]) catch return;
            if (n == 0) return;
            out_file.writeAll(buf[0..n]) catch return;
            checksum.update(buf[0..n]);
            remaining -= n;
        }
        const comp_msg = Protocol.read_message(alloc, reader.interface()) catch return;
        defer comp_msg.deinit();
        const expected_checksum = comp_msg.value.file_complete.checksum;
        const actual = checksum.finalResult();
        const actual_hex = std.fmt.bytesToHex(actual, .lower);
        if (!std.mem.eql(u8, &actual_hex, expected_checksum)) {
            out_file.close();
            const full_path = std.fs.path.join(alloc, &.{ user_config.download_dir, header.path }) catch return;
            std.fs.deleteFileAbsolute(full_path) catch {};
            return FileTransferErrors.ChecksumMisMatch;
        }
        on_progress(.{ .current_file = header.path, .files_done = i + 1, .files_total = offer.total_files, .bytes_sent = offer.total_size - remaining, .bytes_total = offer.total_size });
    }
    const tc = Protocol.read_message(alloc, reader.interface()) catch return;
    defer tc.deinit();
    Protocol.write_message(alloc, &writer.interface, .{ .ack = {} }) catch return;
    writer.interface.flush() catch return;
}
pub fn sendFiles(alloc: std.mem.Allocator, peer: Peer, files: []const fs_utils.FileEntry, user_config: Config, on_progress: *const fn (Progress) void) !void {
    var connect_addr = peer.address;
    connect_addr.setPort(peer.port);
    const stream = try std.net.tcpConnectToAddress(connect_addr);
    defer stream.close();
    tuneSocket(stream.handle);
    var read_buf: [4096]u8 = undefined;
    var write_buf: [256 * 1024]u8 = undefined;
    var reader = stream.reader(&read_buf);
    var writer = stream.writer(&write_buf);

    const transfer_id = try Config.generateUuidV4(alloc);
    var total_size: u64 = 0;
    for (files) |f| total_size += f.size;
    var file_info = try alloc.alloc(Protocol.FileInfo, files.len);
    for (files, 0..) |f, i|
        file_info[i] = .{ .id = try Config.generateUuidV4(alloc), .path = f.relative_path, .size = f.size, .modified = @intCast(f.modified) };
    try Protocol.write_message(alloc, &writer.interface, .{ .transfer_offer = .{ .transfer_id = transfer_id, .device_id = user_config.device_id, .alias = user_config.alias, .files = file_info, .total_size = total_size, .total_files = @intCast(files.len) } });
    try writer.interface.flush();
    const response = try Protocol.read_message(alloc, reader.interface());
    defer response.deinit();
    if (!response.value.transfer_response.accepted) return FileTransferErrors.TransferRejected;

    var bytes_sent: u64 = 0;
    for (files, file_info, 0..) |f, info, i| {
        const file = try std.fs.openFileAbsolute(f.absolute_path, .{});
        defer file.close();

        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        var buf: [512 * 1024]u8 = undefined;

        try Protocol.write_message(alloc, &writer.interface, .{ .file_header = .{
            .id = info.id,
            .path = f.relative_path,
            .size = f.size,
        } });

        var remaining: u64 = f.size;
        while (remaining > 0) {
            const n = try file.read(&buf);
            if (n == 0) break;
            try writer.interface.writeAll(buf[0..n]);
            hash.update(buf[0..n]);
            remaining -= n;
            bytes_sent += n;
        }
        const final_hash = hash.finalResult();
        const checksum_hex = std.fmt.bytesToHex(final_hash, .lower);
        try Protocol.write_message(alloc, &writer.interface, .{ .file_complete = .{
            .id = info.id,
            .checksum = &checksum_hex,
        } });
        try writer.interface.flush();

        on_progress(.{ .current_file = f.relative_path, .files_done = i + 1, .files_total = files.len, .bytes_sent = bytes_sent, .bytes_total = total_size });
    }
    try Protocol.write_message(alloc, &writer.interface, .{ .transfer_complete = {} });
    try writer.interface.flush();
    const ack = try Protocol.read_message(alloc, reader.interface());
    defer ack.deinit();
}

const testing = std.testing;

test "isPathSafe allows simple filename" {
    try testing.expect(isPathSafe("readme.txt"));
}

test "isPathSafe allows nested path" {
    try testing.expect(isPathSafe("docs/images/logo.png"));
}

test "isPathSafe allows deeply nested path" {
    try testing.expect(isPathSafe("a/b/c/d/e/file.txt"));
}

test "isPathSafe rejects absolute path" {
    try testing.expect(!isPathSafe("/etc/passwd"));
}

test "isPathSafe rejects path traversal with .." {
    try testing.expect(!isPathSafe("../secret.txt"));
}

test "isPathSafe rejects path traversal mid-path" {
    try testing.expect(!isPathSafe("docs/../../etc/passwd"));
}

test "isPathSafe rejects null bytes" {
    try testing.expect(!isPathSafe("file\x00.txt"));
}

test "isPathSafe allows single dot component" {
    try testing.expect(isPathSafe("./file.txt"));
}

test "isPathSafe allows dotfiles" {
    try testing.expect(isPathSafe(".gitignore"));
}

test "isPathSafe allows empty path" {
    try testing.expect(isPathSafe(""));
}
test "single file transfer over loopback" {
    const alloc = testing.allocator;

    // Create temp input file
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile("test.txt", .{});
    try f.writeAll("hello world");
    f.close();

    // Create temp output dir
    var out_tmp = testing.tmpDir(.{});
    defer out_tmp.cleanup();
    const out_dir = try out_tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(out_dir);

    // Start TCP listener on a random port
    const addr = try std.net.Address.parseIp("127.0.0.1", 0); // port 0 = OS picks one
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    //const listen_port = server.listen_address.getPort();

    // Spawn server thread — accepts one connection, receives files
    const server_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.net.Server) void {
            const conn = s.accept() catch return;
            defer conn.stream.close();
        }
    }.run, .{&server});

    // Client: connect and send
    const in_path = try tmp.dir.realpathAlloc(alloc, "test.txt");
    defer alloc.free(in_path);

    server_thread.join();

    // Verify output file exists and matches
    const out_file = try out_tmp.dir.openFile("test.txt", .{});
    defer out_file.close();
    // read and compare content
}
