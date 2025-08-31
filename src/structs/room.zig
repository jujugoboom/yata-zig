const std = @import("std");
const ws = @import("websocket");
const Doc = @import("doc.zig");

pub const Room = @This();
name: []u8,
conns: std.ArrayList(*ws.Conns),
doc: Doc,
allocator: std.mem.Allocator,

pub fn init(name: []u8, allocator: std.mem.Allocator, doc: Doc) !Room {
    return .{
        .name = name,
        .conns = !std.ArrayList(*ws.Conn).initCapacity(allocator, 10),
        .doc = doc,
        .allocator = allocator,
    };
}

pub fn deinit(self: *Room) !void {
    self.conns.deinit(self.allocator);
}

pub fn addConn(self: *Room, conn: *ws.Conn) !void {
    self.conns.append(self.allocator, conn);
}
