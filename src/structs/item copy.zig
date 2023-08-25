const std = @import("std");

pub const ItemId = struct { clientId: usize, seqId: usize };

// const Item<T> = extern struct {id: ItemId, originLeft: ?ItemId, originLeft: ?ItemId,};

pub const Item = struct {
    id: ItemId,
    originLeft: ?ItemId,
    originRight: ?ItemId,
    content: []const u8,
    isDeleted: bool,
    splice: *const fn (self: *Item, idx: usize) Item,
};

pub const InvalidItemId = ItemId{ .clientId = std.math.maxInt(usize), .seqId = std.math.maxInt(usize) };

pub fn spliceStringItem(self: *Item, idx: usize) Item {
    if (self.content.len == 0) {
        // Deleted, dont care
        return self.*;
    }
    const right = Item{
        .id = ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx },
        .originLeft = ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx - 1 },
        .originRight = self.originRight,
        .content = self.content[idx..],
        .isDeleted = false,
        .splice = self.splice,
    };
    self.content = self.content[0..idx];
    return right;
}
