const std = @import("std");
const Protocol = @import("protocol.zig");
const transfer = @import("transfer.zig");
const Peer = @import("peer.zig").Peer;

const ESC = "\x1b[";
const CLEAR_LINE = ESC ++ "2K";
const CURSOR_START = "\r";
const CURSOR_UP_ONE = ESC ++ "A";
const HIDE_CURSOR = ESC ++ "?25l";
const SHOW_CURSOR = ESC ++ "?25h";
const BOLD = ESC ++ "1m";
const DIM = ESC ++ "2m";
const RESET = ESC ++ "0m";
const GREEN = ESC ++ "32m";
const RED = ESC ++ "31m";
const CYAN = ESC ++ "36m";
const MAGENTA = ESC ++ "35m";

fn write(comptime fmt: []const u8, args: anytype) void {
    std.debug.print(fmt, args);
}

fn writeStr(s: []const u8) void {
    std.debug.print("{s}", .{s});
}

pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;
    while (size >= 1024.0 and unit_idx < units.len - 1) {
        size /= 1024.0;
        unit_idx += 1;
    }
    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ size, units[unit_idx] }) catch "?";
}

pub fn clearLine() void {
    write(CLEAR_LINE ++ CURSOR_START, .{});
}

pub fn cursorUp(n: usize) void {
    for (0..n) |_| {
        writeStr(CURSOR_UP_ONE);
    }
}

pub fn hideCursor() void {
    writeStr(HIDE_CURSOR);
}

pub fn showCursor() void {
    writeStr(SHOW_CURSOR);
}

// ── Peer Display ──

pub fn printPeerList(peers: []const Peer) usize {
    if (peers.len == 0) {
        clearLine();
        write(DIM ++ "  No peers found..." ++ RESET ++ "\n", .{});
        return 1;
    }
    for (peers, 0..) |p, i| {
        clearLine();
        write(CYAN ++ "  [{d}]" ++ RESET ++ " {s} " ++ DIM ++ "({s})" ++ RESET ++ "\n", .{
            i + 1, p.alias, p.device_id,
        });
    }
    return peers.len;
}

pub fn promptTransferOffer(offer: Protocol.TransferOfferPayload) bool {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, offer.total_size);

    write("\n" ++ BOLD ++ MAGENTA ++ "  Incoming transfer" ++ RESET ++ "\n", .{});
    write("  From: " ++ CYAN ++ "{s}" ++ RESET ++ "\n", .{offer.alias});
    write("  Files: {d} ({s})\n", .{ offer.total_files, size_str });

    for (offer.files) |f| {
        var fbuf: [32]u8 = undefined;
        const fsz = formatSize(&fbuf, f.size);
        write(DIM ++ "    {s}" ++ RESET ++ "  {s}\n", .{ f.path, fsz });
    }

    write("\n  Accept? " ++ BOLD ++ "[y/N]" ++ RESET ++ " ", .{});

    var buf: [16]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return false;
    if (n == 0) return false;
    const answer = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    return answer.len > 0 and (answer[0] == 'y' or answer[0] == 'Y');
}

pub fn promptPeerSelection(peers: []const Peer) ?usize {
    write("\n" ++ BOLD ++ "  Select a peer:" ++ RESET ++ "\n", .{});
    for (peers, 0..) |p, i| {
        write(CYAN ++ "  [{d}]" ++ RESET ++ " {s} " ++ DIM ++ "({s})" ++ RESET ++ "\n", .{
            i + 1, p.alias, p.device_id,
        });
    }
    write("\n  Peer number: ", .{});

    var buf: [16]u8 = undefined;
    const n = std.fs.File.stdin().read(&buf) catch return null;
    if (n == 0) return null;
    const line = std.mem.trim(u8, buf[0..n], &std.ascii.whitespace);
    const choice = std.fmt.parseInt(usize, line, 10) catch return null;
    if (choice < 1 or choice > peers.len) return null;
    return choice - 1;
}

// ── Progress ──

const BAR_WIDTH = 24;
const BAR_FILL = "\xe2\x96\x88"; // █
const BAR_EMPTY = "\xe2\x96\x91"; // ░

pub fn printProgress(p: transfer.Progress) void {
    const pct: u64 = if (p.bytes_total > 0) p.bytes_sent * 100 / p.bytes_total else 0;
    const filled: usize = @intCast(pct * BAR_WIDTH / 100);
    const empty: usize = BAR_WIDTH - filled;

    var sent_buf: [32]u8 = undefined;
    var total_buf: [32]u8 = undefined;
    const sent_str = formatSize(&sent_buf, p.bytes_sent);
    const total_str = formatSize(&total_buf, p.bytes_total);

    // Truncate filename if too long
    const max_name_len = 20;
    var name_buf: [max_name_len + 3]u8 = undefined;
    const display_name: []const u8 = if (p.current_file.len > max_name_len) blk: {
        @memcpy(name_buf[0..3], "...");
        @memcpy(name_buf[3..], p.current_file[p.current_file.len - max_name_len ..]);
        break :blk name_buf[0 .. max_name_len + 3];
    } else p.current_file;

    clearLine();
    writeStr("  " ++ GREEN);
    for (0..filled) |_| writeStr(BAR_FILL);
    writeStr(RESET);
    for (0..empty) |_| writeStr(BAR_EMPTY);
    write(" " ++ BOLD ++ "{d}%" ++ RESET ++ "  {s}  ({d}/{d})  {s} / {s}", .{
        pct, display_name, p.files_done, p.files_total, sent_str, total_str,
    });
}

pub fn printTransferComplete(files_total: usize, bytes_total: u64) void {
    var buf: [32]u8 = undefined;
    const total_str = formatSize(&buf, bytes_total);
    write("\n\n" ++ GREEN ++ BOLD ++ "  Transfer complete" ++ RESET ++ "\n", .{});
    write("  {d} file(s), {s}\n\n", .{ files_total, total_str });
}

pub fn printBanner(alias: []const u8, device_id: []const u8, port: u16) void {
    write("\n" ++ BOLD ++ MAGENTA ++ "  inari todoke" ++ RESET ++ " " ++ DIM ++ "v0.1" ++ RESET ++ "\n", .{});
    write("  {s} " ++ DIM ++ "({s})" ++ RESET ++ "\n", .{ alias, device_id });
    write("  Listening on port {d}\n\n", .{port});
}

const spinner_frames = [_][]const u8{ "\xe2\xa0\x8b", "\xe2\xa0\x99", "\xe2\xa0\xb9", "\xe2\xa0\xb8", "\xe2\xa0\xbc", "\xe2\xa0\xb4", "\xe2\xa0\xa6", "\xe2\xa0\xa7", "\xe2\xa0\x87", "\xe2\xa0\x8f" };
var spinner_idx: usize = 0;

pub fn printDiscovering() void {
    clearLine();
    write("  {s} " ++ DIM ++ "Discovering peers..." ++ RESET, .{spinner_frames[spinner_idx]});
    spinner_idx = (spinner_idx + 1) % spinner_frames.len;
}

pub fn printSendStart(file_count: usize, total_size: u64, target_alias: []const u8) void {
    var size_buf: [32]u8 = undefined;
    const size_str = formatSize(&size_buf, total_size);
    write("\n  Sending {d} file(s) ({s}) to " ++ CYAN ++ "{s}" ++ RESET ++ "\n", .{
        file_count, size_str, target_alias,
    });
}

pub fn printError(comptime fmt: []const u8, args: anytype) void {
    write("\n" ++ RED ++ "  Error: " ++ RESET ++ fmt ++ "\n", args);
}
