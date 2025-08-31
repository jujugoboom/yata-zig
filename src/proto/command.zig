const std = @import("std");

pub const Command = struct {
    ptr: *anyopaque,
    serializeFn: *const fn (ptr: *anyopaque, comptime T: type)
};
