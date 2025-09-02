const std = @import("std");
const websocket = @import("websocket");
const App = @import("../server/app.zig");

const Command = @This();
execute: *const fn (*anyopaque, conn: *websocket.Conn, app: App) anyerror!void,
serialize: *const fn (*anyopaque, allocator: std.mem.Allocator) anyerror![]const u8,
deserialize: *const fn (data: []const u8, allocator: std.mem.Allocator) anyerror!anyopaque,
pub fn init(ptr: anytype) Command {
    const T = @TypeOf(ptr);
    const ptr_info = @typeInfo(T);

    const gen = struct {
        fn getSelf(pointer: *anyopaque) T {
            return @ptrCast(@alignCast(pointer));
        }
        pub fn execute(pointer: *anyopaque, conn: *websocket.Conn, app: App) anyerror!void {
            const self = getSelf(pointer);
            return ptr_info.pointer.child.execute(self, conn, app);
        }

        pub fn serialize(pointer: *anyopaque, allocator: std.mem.Allocator) anyerror![]const u8 {
            const self = getSelf(pointer);
            const value = try ptr_info.pointer.child.toValue(self, allocator);
            defer 

            var buf = std.io.Writer.Allocating.init(allocator);
            defer buf.deinit();
            try std.json.fmt(value, .{}).format(&buf.writer);
            return try buf.toOwnedSlice();
        }
        pub fn deserialize(data: []const u8, allocator: std.mem.Allocator) anyerror!*T {
            const parsed = try std.json.parseFromSlice(data_t, allocator, data, .{});
            defer parsed.deinit();
            const inner_data: data_t = parsed.value;
            return try gen.fromInnerData(inner_data, allocator);
        }
    };

    return .{
        .execute = gen.execute,
        .serialize = gen.serialize,
        .deserialize = gen.deserialize,
    };
}
