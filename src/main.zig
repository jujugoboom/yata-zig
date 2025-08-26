const std = @import("std");
const ws = @import("websocket");
const Handler = @import("server/handler.zig").Handler;
const App = @import("server/app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try ws.Server(Handler).init(allocator, .{
        .port = 9224,
        .address = "127.0.0.1",
        .handshake = .{
            .timeout = 3,
            .max_size = 1024,
            // since we aren't using hanshake.headers
            // we can set this to 0 to save a few bytes.
            .max_headers = 0,
        },
    });

    // Arbitrary (application-specific) data to pass into each handler
    // Pass void ({}) into listen if you have none
    var app: App = .{
        .rooms = std.StringHashMap([]*ws.Conn).init(allocator),
        .allocator = allocator,
    };
    // this blocks
    try server.listen(&app);
}
