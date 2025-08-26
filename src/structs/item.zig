const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

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
    splice: *const fn (self: *Item, idx: usize) anyerror!*Item,
    allocatedContent: bool,
    pub const ItemSplice = *const fn (self: *Item, idx: usize) anyerror!*Item;
    /// Inits new item with allocator. Caller is responsible for calling Item.deinit().
    pub fn init(id: ItemId, originLeft: ItemId, originRight: ?ItemId, left: ?*Item, right: ?*Item, content: []const u8, isDeleted: bool, allocator: std.mem.Allocator, splice: ItemSplice, allocatedContent: bool) !*Item {
        const new_item = try allocator.create(Item);
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
        const content = try self.allocator.alloc(u8, self.content.len);
        @memcpy(content, self.content);
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

    const ItemData = struct {
        id: ItemId,
        originLeft: ItemId,
        originRight: ?ItemId,
        right: ?*ItemData,
        content: []const u8,
        isDeleted: bool,
        splice: []const u8,
    };

    fn deinit_item_data(self: *Item, data: *ItemData) void {
        var right = data.right;
        while (right != null) {
            const curr = right;
            right = right.?.right;
            self.allocator.destroy(curr.?);
        }
        self.allocator.destroy(data);
    }

    fn get_splice_string(self: Item) []const u8 {
        if (self.splice == &spliceStringItem) {
            return "string";
        }
        return "unknown";
    }

    fn to_data(self: *Item) !*ItemData {
        const data = try self.allocator.create(ItemData);
        data.* = .{
            .id = self.id,
            .originLeft = self.originLeft,
            .originRight = self.originRight,
            .right = if (self.right != null) try self.right.?.to_data() else null,
            .content = self.content,
            .isDeleted = self.isDeleted,
            .splice = self.get_splice_string(),
        };
        return data;
    }

    fn get_splice(splice: []const u8) ItemSplice {
        if (std.mem.eql(u8, splice, "string")) {
            return &spliceStringItem;
        }
        return &spliceStringItem;
    }

    fn from_data(item_data: *const ItemData, allocator: std.mem.Allocator) !*Item {
        const content = try allocator.alloc(u8, item_data.content.len);
        @memcpy(content, item_data.content);
        const item = try Item.init(
            item_data.id,
            item_data.originLeft,
            item_data.originRight,
            null,
            if (item_data.right != null) try Item.from_data(item_data.right.?, allocator) else null,
            content,
            item_data.isDeleted,
            allocator,
            Item.get_splice(item_data.splice),
            true,
        );
        var prev_item = item;
        var next_item = item.right;
        while (next_item != null) {
            next_item.?.left = prev_item;
            prev_item = next_item.?;
            next_item = next_item.?.right;
        }
        return item;
    }

    pub fn serialize(self: *Item) ![]const u8 {
        const item_data = try self.to_data();
        defer self.deinit_item_data(item_data);
        var buf = std.io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const formatter = std.json.fmt(item_data, .{});
        try formatter.format(&buf.writer);
        return try buf.toOwnedSlice();
    }

    pub fn deserialize(value: []const u8, allocator: std.mem.Allocator) !*Item {
        const parsed = try std.json.parseFromSlice(ItemData, allocator, value, .{});
        defer parsed.deinit();
        return try Item.from_data(&parsed.value, allocator);
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

test "item serialization" {
    const test_item = try Item.init(
        .{ .clientId = 1, .seqId = 1 },
        .{ .clientId = 1, .seqId = 0 },
        null,
        null,
        null,
        "Hello",
        false,
        testing.allocator,
        &spliceStringItem,
        false,
    );
    defer test_item.deinit();
    const serialized = try test_item.serialize();
    defer testing.allocator.free(serialized);

    const deserialized_item = try Item.deserialize(serialized, testing.allocator);
    defer deserialized_item.deinit();
    const serialized_2 = try deserialized_item.serialize();
    defer testing.allocator.free(serialized_2);
    try expect(std.mem.eql(u8, serialized, serialized_2));

    const test_item2 = try Item.init(
        .{ .clientId = 1, .seqId = 1 },
        .{ .clientId = 1, .seqId = 0 },
        null,
        null,
        null,
        "",
        false,
        testing.allocator,
        &spliceStringItem,
        false,
    );
    defer test_item2.deinit();
    const serialized_3 = try test_item2.serialize();
    defer testing.allocator.free(serialized_3);
}
