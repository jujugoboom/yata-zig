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
    pub fn execute(self: SyncRoomCommand, conn: *websocket.Conn, app: App) !void {
        if (!app.rooms.contains(self.room_name)) {
            //TODO: Maybe do something here? I dunno, figure it out with client stuff
            return;
        }
        const room = app.rooms.get(self.room_name).?;
        const update = try room.doc.getUpdate(self.version);
        const room_sync = RoomSyncCommand{
            .room_name = self.room_name,
            .delta = update,
        };
        const command_json = try room_sync.serialize();
        defer update.allocator.free(command_json);
        conn.writeText(command_json);
    }
};

pub const RoomSyncCommand = struct {
    room_name: []const u8,
    delta: *doc.DocDelta,

    pub fn execute(self: RoomSyncCommand, conn: *websocket.Conn, app: App) !void {
        _ = conn;
        if (!app.rooms.contains(self.room_name)) {
            //TODO: Maybe do something here? I dunno, figure it out with client stuff
            return;
        }
        const room = app.rooms.get(self.room_name).?;
        try room.doc.mergeDelta(self.delta);
    }

    pub fn jsonStringify(self: RoomSyncCommand, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("room_name");
        try jws.value(self.room_name);
        const delta_str = try self.delta.serialize();
        defer try jws.objectField("delta");
        try jws.value(delta_str);
    }
};
