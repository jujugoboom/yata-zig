const std = @import("std");

pub const ItemId = struct {
    clientId: usize,
    seqId: usize,
    pub fn eql(self: ItemId, other: ItemId) bool {
        return self.clientId == other.clientId and self.seqId == other.seqId;
    }
};

// const Item<T> = extern struct {id: ItemId, originLeft: ?ItemId, originLeft: ?ItemId,};

pub const Item = struct { id: ItemId, originLeft: ?ItemId, originRight: ?ItemId, left: ?*Item, right: ?*Item, content: []const u8, isDeleted: bool, allocator: std.mem.Allocator, splice: *const fn (self: *Item, idx: usize) anyerror!*Item };

pub const InvalidItemId = ItemId{ .clientId = std.math.maxInt(usize), .seqId = std.math.maxInt(usize) };

pub fn spliceStringItem(self: *Item, idx: usize) !*Item {
    std.debug.print("SPLITTING: {any}\n\n", .{self});
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
    };
    self.content = self.content[0..idx];
    self.right = right;
    return right;
}
