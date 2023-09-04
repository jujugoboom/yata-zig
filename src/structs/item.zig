const std = @import("std");

/// ItemID for item
pub const ItemId = struct {
    clientId: usize,
    seqId: usize,
    pub fn eql(self: ItemId, other: ?ItemId) bool {
        return other != null and self.clientId == other.?.clientId and self.seqId == other.?.seqId;
    }
    pub fn hash(self: ItemId) u64 {
        // Basic hash fn
        if (self.clientId == std.math.maxInt(usize)) {
            return 0;
        }
        var hash_val: u64 = 23;
        hash_val = hash_val * 31 + self.clientId;
        hash_val = hash_val * 31 + self.seqId;
        return hash_val;
    }
};

const ItemIdContext = struct {
    pub fn eql(self: ItemIdContext, a: ItemId, b: ItemId) bool {
        _ = self;
        return a.eql(b);
    }
    pub fn hash(self: ItemIdContext, a: ItemId) u64 {
        _ = self;
        return a.hash();
    }
};

pub const ItemIdSet = std.HashMap(ItemId, void, ItemIdContext, 80);

const ItemSplice = *const fn (self: *Item, idx: usize) anyerror!*Item;

/// Main item struct
/// TODO: Handle any content type with len
pub const Item = struct {
    id: ItemId,
    originLeft: ItemId,
    originRight: ?ItemId,
    left: ?*Item,
    right: ?*Item,
    content: []const u8,
    isDeleted: bool,
    allocator: std.mem.Allocator,
    splice: ItemSplice,
    allocatedContent: bool,
    /// Inits new item with allocator. Caller is responsible for calling Item.deinit().
    pub fn init(id: ItemId, originLeft: ItemId, originRight: ?ItemId, left: ?*Item, right: ?*Item, content: []const u8, isDeleted: bool, allocator: std.mem.Allocator, splice: ItemSplice, allocatedContent: bool) !*Item {
        var new_item = try allocator.create(Item);
        new_item.* = .{ .id = id, .originLeft = originLeft, .originRight = originRight, .left = left, .right = right, .content = content, .isDeleted = isDeleted, .allocator = allocator, .splice = splice, .allocatedContent = allocatedContent };
        return new_item;
    }
    /// Deinits self, calling free on content if it is heap allocated
    pub fn deinit(self: *Item) void {
        if (self.allocatedContent) self.allocator.free(self.content);
        if (self.left) |left| {
            left.right = null;
        }
        if (self.right) |right| {
            right.left = null;
        }
        self.left = null;
        self.right = null;
        self.allocator.destroy(self);
    }
    /// Basic formatting for item struct
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
    /// Clones self into new item allocated with current item allocator. Caller responsible for calling Item.deinit() on returned item
    pub fn clone(self: *Item) !*Item {
        var content = try self.allocator.alloc(u8, self.content.len);
        @memcpy(content.ptr, self.content.ptr, self.content.len);
        return try Item.init(self.id, self.originLeft, self.originRight, null, null, content, self.isDeleted, self.allocator, self.splice, true);
    }

    pub fn eql(self: Item, b: ?Item) bool {
        if (b == null) {
            return false;
        }
        return self.id.eql(b.?.id);
    }

    pub fn hash(self: Item) u64 {
        return self.id.hash();
    }
};

pub const ItemContext = struct {
    pub fn eql(self: ItemContext, a: Item, b: Item) bool {
        _ = self;
        return a.eql(b);
    }
    pub fn hash(self: ItemIdContext, a: Item) u64 {
        _ = self;
        return a.hash();
    }
};

/// ItemId with maxInt clientId and seqId, used as a sentinel value for document head
pub const HeadItemId = ItemId{ .clientId = std.math.maxInt(usize), .seqId = 0 };

/// Splices string items, abstracted away from item struct to allow future items to accept any content type
pub fn spliceStringItem(self: *Item, idx: usize) !*Item {
    if (self.content.len == 0) {
        // Deleted, dont care
        return self;
    }
    const right = try Item.init(ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx }, self.id, self.originRight, self, self.right, self.content[idx..], false, self.allocator, self.splice, false);
    self.content = self.content[0..idx];
    self.right = right;
    return self;
}
