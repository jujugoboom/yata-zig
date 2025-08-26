const std = @import("std");
const websocket = @import("websocket");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // create the client
    var client = try websocket.Client.init(allocator, .{
        .port = 9224,
        .host = "localhost",
    });
    defer client.deinit();

    // send the initial handshake request
    const request_path = "/ws";
    try client.handshake(request_path, .{
        .timeout_ms = 1000,
        // Raw headers to send, if any.
        // A lot of servers require a Host header.
        // Separate multiple headers using \r\n
        .headers = "Host: localhost:9224",
    });
}
