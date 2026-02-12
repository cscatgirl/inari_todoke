const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

pub const MAX_MESSAGE_SIZE: u32 = 1_048_576; // 1 MB

pub const MessageType = enum { announce, transfer_offer, transfer_response, file_header, file_complete, transfer_complete, ack };

pub const Message = union(MessageType) {
    announce: AnnouncePayload,
    transfer_offer: TransferOfferPayload,
    transfer_response: TransferResponsePayload,
    file_header: FileHeaderPayload,
    file_complete: FileCompletePayload,
    transfer_complete: void,
    ack: void,
};

pub const AnnouncePayload = struct { alias: []const u8, device_id: []const u8, version: u32, port: u16 };
pub const FileInfo = struct { id: []const u8, path: []const u8, size: u64, modified: i64 };
pub const TransferOfferPayload = struct { transfer_id: []const u8, device_id: []const u8, alias: []const u8, files: []const FileInfo, total_size: u64, total_files: u32 };
pub const TransferResponsePayload = struct {
    transfer_id: []const u8,
    accepted: bool,
};
pub const FileHeaderPayload = struct {
    id: []const u8,
    path: []const u8,
    size: u64,
};
pub const FileCompletePayload = struct {
    id: []const u8,
    checksum: []const u8,
};

pub fn write_message(alloc: Allocator, writer: anytype, msg: Message) !void {
    var json_buf = std.io.Writer.Allocating.init(alloc);
    try std.json.Stringify.value(msg, .{}, &json_buf.writer);
    const json = try json_buf.toOwnedSlice();
    defer json_buf.deinit();
    defer alloc.free(json);

    if (json.len > MAX_MESSAGE_SIZE) return error.MessageTooLarge;

    const len: u32 = @intCast(json.len);
    const len_be = std.mem.nativeToBig(u32, len);
    try writer.writeAll(std.mem.asBytes(&len_be));
    try writer.writeAll(json);
}

pub fn read_message(alloc: Allocator, reader: anytype) !std.json.Parsed(Message) {
    var len_buf: [4]u8 = undefined;
    try reader.readSliceAll(&len_buf);
    const len = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, &len_buf));

    if (len > MAX_MESSAGE_SIZE) return error.MessageTooLarge;

    const buf = try alloc.alloc(u8, len);
    defer alloc.free(buf);
    try reader.readSliceAll(buf);

    return std.json.parseFromSlice(Message, alloc, buf, .{ .allocate = .alloc_always });
}

// ---- Tests ----

test "round-trip announce" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = Message{ .announce = .{
        .alias = "test-device",
        .device_id = "a1b2c3d4-5678-4abc-9def-0123456789ab",
        .version = 1,
        .port = 53318,
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    const a = parsed.value.announce;
    try testing.expectEqualStrings("test-device", a.alias);
    try testing.expectEqualStrings("a1b2c3d4-5678-4abc-9def-0123456789ab", a.device_id);
    try testing.expectEqual(@as(u32, 1), a.version);
    try testing.expectEqual(@as(u16, 53318), a.port);
}

test "round-trip transfer offer with multiple files" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const files = [_]FileInfo{
        .{ .id = "file-1", .path = "docs/readme.md", .size = 4096, .modified = 1707500000 },
        .{ .id = "file-2", .path = "docs/images/logo.png", .size = 102400, .modified = 1707500100 },
    };

    const original = Message{ .transfer_offer = .{
        .transfer_id = "xfer-001",
        .device_id = "a1b2c3d4",
        .alias = "sender",
        .files = &files,
        .total_size = 106496,
        .total_files = 2,
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    const offer = parsed.value.transfer_offer;
    try testing.expectEqualStrings("xfer-001", offer.transfer_id);
    try testing.expectEqualStrings("a1b2c3d4", offer.device_id);
    try testing.expectEqualStrings("sender", offer.alias);
    try testing.expectEqual(@as(u64, 106496), offer.total_size);
    try testing.expectEqual(@as(u32, 2), offer.total_files);
    try testing.expectEqual(@as(usize, 2), offer.files.len);
    try testing.expectEqualStrings("file-1", offer.files[0].id);
    try testing.expectEqualStrings("docs/readme.md", offer.files[0].path);
    try testing.expectEqual(@as(u64, 4096), offer.files[0].size);
    try testing.expectEqualStrings("docs/images/logo.png", offer.files[1].path);
    try testing.expectEqual(@as(u64, 102400), offer.files[1].size);
}

test "round-trip transfer response accepted" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = Message{ .transfer_response = .{
        .transfer_id = "xfer-001",
        .accepted = true,
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    try testing.expectEqualStrings("xfer-001", parsed.value.transfer_response.transfer_id);
    try testing.expect(parsed.value.transfer_response.accepted);
}

test "round-trip transfer response rejected" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = Message{ .transfer_response = .{
        .transfer_id = "xfer-002",
        .accepted = false,
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    try testing.expectEqualStrings("xfer-002", parsed.value.transfer_response.transfer_id);
    try testing.expect(!parsed.value.transfer_response.accepted);
}

test "round-trip file header" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = Message{ .file_header = .{
        .id = "file-1",
        .path = "projects/src/main.zig",
        .size = 65536,
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    const fh = parsed.value.file_header;
    try testing.expectEqualStrings("file-1", fh.id);
    try testing.expectEqualStrings("projects/src/main.zig", fh.path);
    try testing.expectEqual(@as(u64, 65536), fh.size);
}

test "round-trip file complete with sha256 checksum" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const original = Message{ .file_complete = .{
        .id = "file-1",
        .checksum = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    } };

    try write_message(alloc, fbs.writer(), original);
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    try testing.expectEqualStrings("file-1", parsed.value.file_complete.id);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        parsed.value.file_complete.checksum,
    );
}

test "round-trip transfer_complete (void payload)" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try write_message(alloc, fbs.writer(), Message{ .transfer_complete = {} });
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    try testing.expectEqual(MessageType.transfer_complete, std.meta.activeTag(parsed.value));
}

test "round-trip ack (void payload)" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try write_message(alloc, fbs.writer(), Message{ .ack = {} });
    fbs.pos = 0;

    const parsed = try read_message(alloc, fbs.reader());
    defer parsed.deinit();

    try testing.expectEqual(MessageType.ack, std.meta.activeTag(parsed.value));
}

test "length prefix is big-endian and matches payload size" {
    const alloc = testing.allocator;
    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try write_message(alloc, fbs.writer(), Message{ .ack = {} });

    const written = fbs.getWritten();
    const len = std.mem.bigToNative(u32, std.mem.bytesToValue(u32, written[0..4]));
    try testing.expectEqual(written.len - 4, len);
}

test "multiple messages in sequence share one stream" {
    const alloc = testing.allocator;
    var buf: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const msg1 = Message{ .announce = .{
        .alias = "peer-a",
        .device_id = "id-a",
        .version = 1,
        .port = 53318,
    } };
    const msg2 = Message{ .transfer_response = .{
        .transfer_id = "xfer-99",
        .accepted = true,
    } };
    const msg3 = Message{ .ack = {} };

    try write_message(alloc, fbs.writer(), msg1);
    try write_message(alloc, fbs.writer(), msg2);
    try write_message(alloc, fbs.writer(), msg3);

    fbs.pos = 0;

    const p1 = try read_message(alloc, fbs.reader());
    defer p1.deinit();
    const p2 = try read_message(alloc, fbs.reader());
    defer p2.deinit();
    const p3 = try read_message(alloc, fbs.reader());
    defer p3.deinit();

    try testing.expectEqualStrings("peer-a", p1.value.announce.alias);
    try testing.expectEqualStrings("xfer-99", p2.value.transfer_response.transfer_id);
    try testing.expectEqual(MessageType.ack, std.meta.activeTag(p3.value));
}

test "read_message rejects oversized length prefix" {
    const alloc = testing.allocator;
    var buf: [8]u8 = undefined;

    const bad_len = MAX_MESSAGE_SIZE + 1;
    const be_val = std.mem.nativeToBig(u32, bad_len);
    buf[0..4].* = std.mem.asBytes(&be_val).*;

    var fbs = std.io.fixedBufferStream(&buf);
    const result = read_message(alloc, fbs.reader());
    try testing.expectError(error.MessageTooLarge, result);
}
