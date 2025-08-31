const std = @import("std");
const websocket = @import("websocket");
const Command = @import("../proto/command.zig");
const App = @import("app.zig");
const Room = @import("../structs/room.zig");
const Doc = @import("../structs/doc.zig").Doc;

pub const JoinRoomCommand = struct {
    room_name: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(room_name: []const u8, allocator: std.mem.Allocator) JoinRoomCommand {
        return .{
            .room_name = room_name,
            .allocator = allocator,
        };
    }

    fn execute(self: *JoinRoomCommand, conn: *websocket.Conn, app: App) !void {
        const maybe_room = try app.rooms.getOrPut(self.room_name);
        if (!maybe_room.found_existing) {
            maybe_room.value_ptr.* = Room.init(
                self.room_name,
                self.allocator,
                try Doc.init(self.allocator),
            );
        }
        const room = maybe_room.value_ptr;
        room.addConn(conn);
    }

    pub fn command(self: *JoinRoomCommand) Command {
        return Command.init(self);
    }
};
