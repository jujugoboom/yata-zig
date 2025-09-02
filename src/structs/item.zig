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

    pub fn fmt(self: ItemId, allocator: std.mem.Allocator) ![]const u8 {
        return try std.fmt.allocPrint(allocator, "{d}_{d}", .{ self.clientId, self.seqId });
    }

    pub fn fromString(str: []const u8) !ItemId {
        var split = std.mem.splitAny(u8, str, "_");
        return .{
            .clientId = try std.fmt.parseInt(usize, split.next().?, 10),
            .seqId = try std.fmt.parseInt(usize, split.next().?, 10),
        };
    }
};

/// Hash context for ItemId
pub const ItemIdHashContext = struct {
    pub fn eql(self: ItemIdHashContext, a: ItemId, b: ItemId) bool {
        _ = self;
        return a.eql(b);
    }
    pub fn hash(self: ItemIdHashContext, a: ItemId) u64 {
        _ = self;
        return a.hash();
    }
};

pub const ItemIdSet = std.HashMap(ItemId, void, ItemIdHashContext, 80);
pub const ItemIdMap = std.HashMap(ItemId, *Item, ItemIdHashContext, 80);

/// Main item struct
/// TODO: Handle any content type with len
pub const Item = struct {
    id: ItemId,
    originLeft: ItemId,
    originRight: ?ItemId,
    left: ?*Item,
    right: ?*Item,

    isDeleted: bool,
    allocator: std.mem.Allocator,
    splice: *const fn (self: *Item, idx: usize) anyerror!*Item,
    allocatedContent: bool,
    pub const ItemSplice = *const fn (self: *Item, idx: usize) anyerror!*Item;
    /// Inits new item with allocator. Caller is responsible for calling Item.deinit().
    pub fn init(
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
    ) !*Item {
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
        return (self.id.eql(b.?.id) and std.mem.eql(u8, self.content, b.?.content) and self.originLeft.eql(b.?.originLeft) and if (self.originRight != null) self.originRight.?.eql(b.?.originRight) else true);
    }

    pub fn hash(self: Item) u64 {
        return self.id.hash();
    }

    pub const ItemData = struct {
        id: ItemId,
        originLeft: ItemId,
        originRight: ?ItemId,
        right: ?ItemId,
        content: []const u8,
        isDeleted: bool,
        splice: []const u8,
    };

    fn getSplice(splice: []const u8) ItemSplice {
        if (std.mem.eql(u8, splice, "string")) {
            return &spliceStringItem;
        }
        return &spliceStringItem;
    }

    fn getSpliceString(self: Item) []const u8 {
        if (self.splice == &spliceStringItem) {
            return "string";
        }
        return "unknown";
    }

    pub fn toData(self: *Item) ItemData {
        return ItemData{
            .id = self.id,
            .originLeft = self.originLeft,
            .originRight = self.originRight,
            .right = if (self.right != null) self.right.?.id else null,
            .content = self.content,
            .isDeleted = self.isDeleted,
            .splice = self.getSpliceString(),
        };
    }

    pub fn fromData(item_data: ItemData, allocator: std.mem.Allocator) !*Item {
        const content = try allocator.alloc(u8, item_data.content.len);
        @memcpy(content, item_data.content);
        return try Item.init(
            item_data.id,
            item_data.originLeft,
            item_data.originRight,
            null,
            null,
            content,
            item_data.isDeleted,
            allocator,
            Item.getSplice(item_data.splice),
            true,
        );
    }

    pub fn serialize(self: *Item) ![]const u8 {
        const item_data = self.toData();
        var buf = std.io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const formatter = std.json.fmt(item_data, .{});
        try formatter.format(&buf.writer);
        return try buf.toOwnedSlice();
    }

    pub fn deserialize(value: []const u8, allocator: std.mem.Allocator) !*Item {
        const parsed: std.json.Parsed(ItemData) = try std.json.parseFromSlice(ItemData, allocator, value, .{});
        defer parsed.deinit();
        return try Item.fromData(parsed.value, allocator);
    }

    pub fn jsonStringify(self: *Item, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField("id");
        try jws.write(self.id);
        try jws.objectField("originLeft");
        try jws.write(self.originLeft);
        try jws.objectField("originRight");
        try jws.write(self.originRight);
        try jws.objectField("right");
        try jws.write(self.right);
        try jws.objectField("isDeleted");
        try jws.write(self.isDeleted);
        try jws.objectField("splice");
        try jws.write(self.getSpliceString());
        try jws.endObject();
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !*Item {
        const value = try std.json.Value.jsonParse(allocator, source, options);
        return Item.jsonParseFromValue(allocator, value, options);
    }

    pub fn jsonParseFromValue(allocator: std.mem.Allocator, source: std.json.Value, options: std.json.ParseOptions) !*Item {
        const obj_map = switch (source) {
            .object => |map| map,
            _ => return error.InvalidValue,
        };
        if (!obj_map.contains("id") or !obj_map.contains("originLeft") or !obj_map.contains("originRight") or !obj_map.contains("isDeleted") or !obj_map.contains("splice")) {
            return error.MissingField;
        }
    }
};

pub const ItemHashContext = struct {
    pub fn eql(self: ItemHashContext, a: Item, b: Item) bool {
        _ = self;
        return a.eql(b);
    }
    pub fn hash(self: ItemIdHashContext, a: Item) u64 {
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
    var right_content = self.content[idx..];
    var left_content = self.content[0..idx];
    var allocated = false;
    if (self.allocatedContent) {
        right_content = try std.fmt.allocPrint(self.allocator, "{s}", .{right_content});
        left_content = try std.fmt.allocPrint(self.allocator, "{s}", .{left_content});
        allocated = true;
        self.allocator.free(self.content);
    }
    const right = try Item.init(
        ItemId{ .clientId = self.id.clientId, .seqId = self.id.seqId + idx },
        self.id,
        self.originRight,
        self,
        self.right,
        right_content,
        false,
        self.allocator,
        self.splice,
        allocated,
    );
    self.content = left_content;
    self.allocatedContent = allocated;
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
