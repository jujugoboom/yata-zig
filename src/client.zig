const std = @import("std");
const websocket = @import("websocket");

export const Client = struct {
    ws_client: websocket.Client,
    pub fn init(host: []const u8, port: u16, allocator: std.mem.Allocator) !Client {
        const client = try websocket.Client.init(allocator, .{
            .host = host,
            .port = port,
        });
        return .{
            .ws_client = client,
        };
    }
};
