const std = @import("std");
const config = @import("config.zig").Config;
const discovery = @import("discovery.zig");
const PeerList = @import("peer.zig").PeerList;
const Peer = @import("peer.zig").Peer;
const transfer = @import("transfer.zig");
const Protocol = @import("protocol.zig");
const fs_util = @import("fs.zig");
const ui = @import("ui.zig");
test {
    _ = @import("protocol.zig");
    _ = @import("fs.zig");
    _ = @import("peer.zig");
    //_ = @import("transfer.zig");
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var arena: std.heap.ArenaAllocator = .init(gpa.allocator());
    const alloc = arena.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.debug.print("Fucking leak", .{});
        } else {
            std.debug.print("No leak", .{});
        }
    }
    defer arena.deinit();
    var user_config = try config.load(alloc);
    var peer_list: PeerList = PeerList.init(alloc);
    const args = try std.process.argsAlloc(alloc);

    // Parse --alias and --device-id flags, collect remaining positional args
    var positional_start: usize = 1;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--alias") and i + 1 < args.len) {
            user_config.alias = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--device-id") and i + 1 < args.len) {
            user_config.device_id = @constCast(args[i + 1]);
            i += 1;
        } else {
            break;
        }
        positional_start = i + 1;
    }

    const rest = args[positional_start..];
    if (rest.len > 0 and std.mem.eql(u8, rest[0], "send")) {
        if (rest.len < 2) {
            std.debug.print("Usage: inari_todoke [--alias NAME] [--device-id ID] send <path> [path...]\n", .{});
            return;
        }
        try runSendMode(alloc, user_config, &peer_list, rest[1..]);
    } else {
        try runListenMode(alloc, user_config, &peer_list);
    }
}

fn onOffer(offer: Protocol.TransferOfferPayload) bool {
    return ui.promptTransferOffer(offer);
}

fn onProgress(p: transfer.Progress) void {
    ui.printProgress(p);
}

fn runListenMode(alloc: std.mem.Allocator, user_config: config, peers: *PeerList) !void {
    _ = try discovery.startBroadcast(alloc, user_config);
    _ = try discovery.startListener(user_config, peers, alloc);
    _ = try transfer.startServer(alloc, user_config, &onOffer, &onProgress);

    ui.printBanner(user_config.alias, user_config.device_id, user_config.listen_port);

    var prev_lines: usize = 0;
    while (true) {
        std.Thread.sleep(3 * std.time.ns_per_s);
        peers.removeStale(15);
        const all_peers = try peers.getAll(alloc);
        defer alloc.free(all_peers);
        if (prev_lines > 0) ui.cursorUp(prev_lines);
        prev_lines = ui.printPeerList(all_peers);
    }
}

fn runSendMode(alloc: std.mem.Allocator, user_config: config, peers: *PeerList, paths: []const []const u8) !void {
    _ = try discovery.startBroadcast(alloc, user_config);
    _ = try discovery.startListener(user_config, peers, alloc);

    // Wait for peers with spinner
    ui.hideCursor();
    var all_peers: []const Peer = &.{};
    while (all_peers.len == 0) {
        ui.printDiscovering();
        std.Thread.sleep(1 * std.time.ns_per_s);
        peers.removeStale(15);
        all_peers = try peers.getAll(alloc);
    }
    ui.showCursor();
    ui.clearLine();

    // Peer selection
    const idx = ui.promptPeerSelection(all_peers) orelse {
        ui.showCursor();
        std.debug.print("Invalid selection.\n", .{});
        return;
    };
    const target = all_peers[idx];
    defer alloc.free(all_peers);

    // Enumerate files
    var file_list = std.ArrayList(fs_util.FileEntry).empty;
    for (paths) |path| {
        const abs_path = try std.fs.cwd().realpathAlloc(alloc, path);
        const entries = try fs_util.enumerateFiles(alloc, abs_path);
        for (entries) |entry| {
            try file_list.append(alloc, entry);
        }
    }
    const files = try file_list.toOwnedSlice(alloc);
    defer alloc.free(files);

    // Compute total size and display send start
    var total_size: u64 = 0;
    for (files) |f| total_size += f.size;
    ui.printSendStart(files.len, total_size, target.alias);

    // Send files
    ui.hideCursor();
    transfer.sendFiles(alloc, target, files, user_config, &onProgress) catch |err| {
        ui.showCursor();
        ui.printError("{}", .{err});
        return;
    };
    ui.showCursor();
    ui.printTransferComplete(files.len, total_size);
}
