const std = @import("std");
const websocket = @import("websocket");
const Command = @import("../proto/command.zig");
const App = @import("app.zig");
const Room = @import("../structs/room.zig");
const doc = @import("../structs/doc.zig");
const Doc = doc.Doc;
const DocVersion = doc.DocVersion;

pub const JoinRoomCommand = struct {
    room_name: []const u8,
    pub fn execute(self: JoinRoomCommand, conn: *websocket.Conn, app: App) !void {
        const maybe_room = try app.rooms.getOrPut(self.room_name);
        if (!maybe_room.found_existing) {
            maybe_room.value_ptr.* = Room.init(
                self.room_name,
                app.allocator,
                Doc.init(app.allocator),
            );
        }
        const room = maybe_room.value_ptr;
        room.addConn(conn);
    }
};

pub const SyncRoomCommand = struct {
    room_name: []const u8,
    version: DocVersion,
};
