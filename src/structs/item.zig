const std = @import("std");

pub const ItemId = struct {
    clientId: usize,
    seqId: usize,
    pub fn eql(self: ItemId, other: ItemId) bool {
        return self.clientId == other.clientId and self.seqId == other.seqId;
    }
};

// const Item<T> = extern struct {id: ItemId, originLeft: ?ItemId, originLeft: ?ItemId,};

pub const Item = struct {
    id: ItemId,
    originLeft: ?ItemId,
    originRight: ?ItemId,
    left: ?*Item,
    right: ?*Item,
    content: []const u8,
    isDeleted: bool,
    allocator: std.mem.Allocator,
    splice: *const fn (self: *Item, idx: usize) anyerror!*Item,
    allocatedContent: bool,
    pub fn format(
        self: Item,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        _ = fmt;
        try writer.print("(id: {any},\n originLeft: {any},\n originRight: {any},\n left: {any},\n right: {any},\n content: {s})\n", .{ self.id, self.originLeft, self.originRight, if (self.left) |left| left.id else null, if (self.right) |right| right.id else null, self.content });
    }
    pub fn clone(self: *Item) !*Item {
        var new_item = try self.allocator.create(Item);
        new_item.* = self.*;
        var content = try self.allocator.alloc(u8, self.content.len);
        @memcpy(content.ptr, self.content.ptr, self.content.len);
        new_item.allocatedContent = true;
        return new_item;
    }
    pub fn deinit(self: *Item) void {
        if (self.allocatedContent) self.allocator.free(self.content);
        self.allocator.destroy(self);
    }
};

pub const InvalidItemId = ItemId{ .clientId = std.math.maxInt(usize), .seqId = std.math.maxInt(usize) };

pub fn spliceStringItem(self: *Item, idx: usize) !*Item {
    if (self.content.len == 0) {
        // Deleted, dont care
        return self;
    }
    const right = try self.allocator.create(Item);
    right.* = .{
        .id = ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx },
        .originLeft = ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx - 1 },
        .originRight = self.originRight,
        .left = self,
        .right = self.right,
        .content = self.content[idx..],
        .isDeleted = false,
        .allocator = self.allocator,
        .splice = self.splice,
        .allocatedContent = false,
    };
    self.content = self.content[0..idx];
    self.right = right;
    return self;
}
