const std = @import("std");
pub const Peer = struct { device_id: []const u8, alias: []const u8, address: std.net.Address, port: u16, last_active: i64 };
pub const PeerList = struct {
    mutex: std.Thread.Mutex,
    peers: std.StringHashMap(Peer),
    alloc: std.mem.Allocator,
    pub fn init(alloc: std.mem.Allocator) PeerList {
        return PeerList{ .mutex = std.Thread.Mutex{}, .peers = .init(alloc), .alloc = alloc };
    }
    pub fn add_or_update(self: *PeerList, peer: Peer) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = try self.peers.getOrPut(peer.device_id);
        result.value_ptr.* = peer;
    }
    pub fn removeStale(self: *PeerList, max_time: i64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const now = std.time.timestamp();
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (now - entry.value_ptr.last_active > max_time) {
                self.peers.removeByPtr(entry.key_ptr);
            }
        }
    }
    pub fn getAll(self: *PeerList, alloc: std.mem.Allocator) ![]Peer {
        self.mutex.lock();
        defer self.mutex.unlock();
        var list = std.ArrayList(Peer).empty;
        var it = self.peers.valueIterator();
        while (it.next()) |entry| {
            try list.append(alloc, entry.*);
        }
        return list.toOwnedSlice(alloc);
    }
    pub fn deinit(self: *PeerList) void {
        self.peers.deinit();
    }
};

const testing = std.testing;

fn testPeer(device_id: []const u8, alias: []const u8, last_active: i64) Peer {
    return Peer{
        .device_id = device_id,
        .alias = alias,
        .address = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 53318),
        .port = 53318,
        .last_active = last_active,
    };
}

test "add_or_update adds a new peer" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    try pl.add_or_update(testPeer("device-aaa", "alice", std.time.timestamp()));
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("alice", all[0].alias);
}

test "add_or_update updates existing peer with same device_id" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    try pl.add_or_update(testPeer("device-bbb", "bob-old", std.time.timestamp()));
    try pl.add_or_update(testPeer("device-bbb", "bob-new", std.time.timestamp()));
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("bob-new", all[0].alias);
}

test "add_or_update with different device_ids adds separate peers" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    try pl.add_or_update(testPeer("device-111", "alice", std.time.timestamp()));
    try pl.add_or_update(testPeer("device-222", "bob", std.time.timestamp()));
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "removeStale removes old peers" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    const now = std.time.timestamp();
    try pl.add_or_update(testPeer("stale-peer", "old", now - 30));
    try pl.add_or_update(testPeer("fresh-peer", "new", now));
    pl.removeStale(15);
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 1), all.len);
    try testing.expectEqualStrings("new", all[0].alias);
}

test "removeStale keeps all peers when none are stale" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    const now = std.time.timestamp();
    try pl.add_or_update(testPeer("peer-a", "a", now));
    try pl.add_or_update(testPeer("peer-b", "b", now));
    pl.removeStale(15);
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 2), all.len);
}

test "removeStale on empty list does nothing" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    pl.removeStale(15);
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);
}

test "getAll returns empty slice when no peers" {
    var pl = PeerList.init(testing.allocator);
    defer pl.deinit();
    const all = try pl.getAll(testing.allocator);
    defer testing.allocator.free(all);
    try testing.expectEqual(@as(usize, 0), all.len);
}
