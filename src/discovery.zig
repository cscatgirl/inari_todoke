const std = @import("std");
const config = @import("config.zig").Config;
const protocol = @import("protocol.zig");
const PeersList = @import("peer.zig").PeerList;
const Peer = @import("peer.zig").Peer;
const net = std.net;
const posix = std.posix;
pub fn startBroadcast(alloc: std.mem.Allocator, usr_config: config) !std.Thread {
    const addr = try net.Address.parseIp("255.255.255.255", 53317);
    const socket_fd = try posix.socket(addr.any.family, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    try posix.setsockopt(socket_fd, std.posix.SOL.SOCKET, std.c.SO.BROADCAST, &std.mem.toBytes(@as(c_int, 1)));
    var json_buf = std.io.Writer.Allocating.init(alloc);
    defer json_buf.deinit();
    try std.json.Stringify.value(protocol.AnnouncePayload{ .alias = usr_config.alias, .device_id = usr_config.device_id, .version = 1, .port = 53317 }, .{}, &json_buf.writer);
    const announce = try json_buf.toOwnedSlice();
    return try std.Thread.spawn(.{}, broadcastLoop, .{ socket_fd, addr.any, addr.getOsSockLen(), announce });
}
fn broadcastLoop(socket: posix.socket_t, sock_addr: posix.sockaddr, addr_len: posix.socklen_t, announce: []const u8) void {
    defer posix.close(socket);
    while (true) {
        _ = posix.sendto(socket, announce, 0, &sock_addr, addr_len) catch continue;
        std.Thread.sleep(5 * std.time.ns_per_s);
    }
}
pub fn startListener(usr_config: config, peers: *PeersList, alloc: std.mem.Allocator) !std.Thread {
    const addr = try net.Address.parseIp("0.0.0.0", 53317);
    const socket_fd = try posix.socket(addr.any.family, posix.SOCK.DGRAM, posix.IPPROTO.UDP);
    try posix.setsockopt(socket_fd, posix.SOL.SOCKET, std.c.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(socket_fd, posix.SOL.SOCKET, std.c.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
    try posix.bind(socket_fd, &addr.any, addr.getOsSockLen());
    return try std.Thread.spawn(.{}, listenerLoop, .{ usr_config, socket_fd, peers, alloc });
}
fn listenerLoop(usr_config: config, socket: posix.socket_t, peers: *PeersList, alloc: std.mem.Allocator) void {
    defer posix.close(socket);
    while (true) {
        var buffer: [1024]u8 = undefined;
        var src_addr: posix.sockaddr = undefined;
        var src_len: posix.socklen_t = @sizeOf(posix.sockaddr);
        const n = posix.recvfrom(socket, &buffer, 0, &src_addr, &src_len) catch continue;
        const message = buffer[0..n];
        const json_obj = std.json.parseFromSlice(protocol.AnnouncePayload, alloc, message, .{ .allocate = .alloc_always }) catch continue;
        const announce_payload = json_obj.value;
        const device_id = alloc.dupe(u8, announce_payload.device_id) catch continue;
        const alias = alloc.dupe(u8, announce_payload.alias) catch continue;
        json_obj.deinit();
        if (!std.mem.eql(u8, device_id, usr_config.device_id)) {
            const peer = Peer{ .device_id = device_id, .alias = alias, .port = usr_config.listen_port, .last_active = std.time.timestamp(), .address = net.Address{ .any = src_addr } };
            peers.add_or_update(peer) catch continue;
        } else {
            alloc.free(device_id);
            alloc.free(alias);
        }
    }
}
