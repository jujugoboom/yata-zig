const std = @import("std");
const ws = @import("websocket");
const Room = @import("../structs/room.zig");

// This is application-specific you want passed into your Handler's
// init function.
const App = @This();

rooms: std.StringHashMap(Room),
allocator: std.mem.Allocator,
