const std = @import("std");
const ws = @import("websocket");

// This is application-specific you want passed into your Handler's
// init function.
pub const App = struct {
    rooms: std.StringHashMap([]*ws.Conn),
    allocator: std.mem.Allocator,
};
