const std = @import("std");
const websocket = @import("websocket");
const App = @import("../server/app.zig");

const Command = @This();
ptr: *anyopaque,
execute: *const fn (*anyopaque, conn: *websocket.Conn, app: App) anyerror!void,
serialize: *const fn (*anyopaque) anyerror![]const u8,
deserialize: *const fn (data: []const u8) anyerror!*anyopaque,

pub fn init(ptr: anytype) Command {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const gen = struct {
        fn getSelf(pointer: *anyopaque) T {
            return @ptrCast(@alignCast(pointer));
        }
        pub fn execute(pointer: *anyopaque, conn: *websocket.Conn, app: App) anyerror!void {
            const self: T = @ptrCast(@alignCast(pointer));
            return ptr_info.pointer.child.execute(self, conn, app);
        }
        pub fn serialize(pointer: *anyopaque) anyerror![]const u8 {
            const self: T = getSelf(pointer);
            return ptr_info.pointer.child.serialize(self);
        }
        pub fn deserialize(data: []const u8) anyerror!*T {
            return ptr_info.pointer.child.deserialize(data);
        }
    };

    return .{
        .ptr = ptr,
        .execute = gen.execute,
        .serialize = gen.serialize,
        .deserialize = gen.dederialize,
    };
}
