const item = @import("item.zig");
const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

/// Possible merge errors
const MergeError = error{ MissingOperation, MissingParent };
const ParseError = error{ InvalidValue, MissingField };

/// Struct to hold delta between two docs. Generated through Doc.delta()
pub const DocDelta = struct {
    delta: ?*item.Item,
    tombstones: item.ItemIdSet,
    allocator: std.mem.Allocator,
    pub fn init(delta: ?*item.Item, tombstones: item.ItemIdSet, allocator: std.mem.Allocator) !*DocDelta {
        const doc_delta = try allocator.create(DocDelta);
        doc_delta.* = .{ .delta = delta, .tombstones = tombstones, .allocator = allocator };
        return doc_delta;
    }
    pub fn deinit(self: *DocDelta) void {
        self.tombstones.deinit();
        var it = DocIterator{ .curr_item = self.delta };
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
        self.allocator.destroy(self);
    }

    const DocDeltaData = struct {
        doc: []const u8,
        tombstones: []std.json.Value,
    };

    pub fn serialize(self: *DocDelta) ![]const u8 {
        var doc_str: []const u8 = try self.allocator.dupe(u8, "{}");
        defer self.allocator.free(doc_str);
        if (self.delta != null) {
            const doc = try Doc.withHead(self.allocator, self.delta.?);
            defer doc.deinitNoItems();
            // Free dummy allocated string
            self.allocator.free(doc_str);
            doc_str = try doc.serialize();
        }
        var buf = std.io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        var tombstone_arr = std.json.Array.init(self.allocator);
        var tombstone_it = self.tombstones.keyIterator();
        while (tombstone_it.next()) |item_id| {
            try tombstone_arr.append(.{
                .string = try item_id.fmt(self.allocator),
            });
        }
        try std.json.fmt(DocDeltaData{
            .doc = doc_str,
            .tombstones = tombstone_arr.items,
        }, .{}).format(
            &buf.writer,
        );
        return buf.toOwnedSlice();
    }

    pub fn deserialize(value: []const u8, allocator: std.mem.Allocator) !*DocDelta {
        const parsed = try std.json.parseFromSlice(
            DocDeltaData,
            allocator,
            value,
            .{},
        );
        defer parsed.deinit();
        const delta_data: DocDeltaData = parsed.value;
        var head: ?*item.Item = null;
        if (!std.mem.eql(u8, delta_data.doc, "{}")) {
            const doc = try Doc.deserialize(delta_data.doc, allocator);
            defer doc.deinitNoItems();
            head = doc.head;
        }
        var tombstone_set = item.ItemIdSet.init(allocator);
        for (delta_data.tombstones) |item_id_str| {
            try tombstone_set.put(try item.ItemId.fromString(item_id_str.string), {});
        }
        return DocDelta.init(head, tombstone_set, allocator);
    }
};

/// Iterator through Doc
const DocIterator = struct {
    curr_item: ?*item.Item,
    pub fn next(self: *DocIterator) ?*item.Item {
        const ret = self.curr_item;
        if (ret) |ret_it| self.curr_item = ret_it.right;
        return ret;
    }
};

pub const DocVersion = std.AutoHashMap(usize, usize);

/// Main doc struct. Contains all logic for YATA CRDT and handles all item creation
pub const Doc = struct {
    head: *item.Item,
    allocator: std.mem.Allocator,
    len: usize,
    items: u32,
    fn createHeadItem(allocator: std.mem.Allocator) !*item.Item {
        return item.Item.init(
            item.HeadItemId,
            item.HeadItemId,
            null,
            null,
            null,
            "",
            false,
            allocator,
            item.spliceStringItem,
            false,
        );
    }
    /// Inits new doc with supplied allocator. Caller is responsible for calling Doc.deinit()
    pub fn init(allocator: std.mem.Allocator) !*Doc {
        const new_doc = try allocator.create(Doc);
        const head_it = try createHeadItem(allocator);
        new_doc.* = .{ .head = head_it, .allocator = allocator, .len = 0, .items = 1 };
        return new_doc;
    }

    /// Basic wrapper around creating a duplicate of a doc
    fn withHead(allocator: std.mem.Allocator, head: *item.Item) !*Doc {
        const new_doc = try allocator.create(Doc);
        var len: usize = 0;
        var items: u32 = 0;
        var it = DocIterator{ .curr_item = head };
        while (it.next()) |curr_item| {
            len += curr_item.content.len;
            items += 1;
        }
        new_doc.* = .{ .head = head, .allocator = allocator, .len = len, .items = items };
        return new_doc;
    }

    /// Doc destructor
    pub fn deinit(self: *Doc) void {
        var it = self.iter();
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
        self.allocator.destroy(self);
    }

    fn deinitNoItems(self: *Doc) void {
        self.allocator.destroy(self);
    }

    /// Creates DocIterator for doc
    pub fn iter(self: *Doc) DocIterator {
        return DocIterator{ .curr_item = self.head };
    }

    pub fn eql(self: *Doc, other: ?*Doc) bool {
        if (other == null) {
            return false;
        }
        var is_eql = true;
        var our_item: ?*item.Item = self.head;
        var other_item: ?*item.Item = other.?.head;
        while (is_eql and !(our_item == null and other_item == null)) {
            is_eql = is_eql and if (our_item != null) our_item.?.eql(if (other_item != null) other_item.?.* else null) else other_item == null;
            our_item = our_item.?.right;
            other_item = other_item.?.right;
        }
        return is_eql;
    }

    /// Clones self into a new doc. Allocates new doc with existing allocator, caller is responsible for calling Doc.deinit() on returned doc.
    pub fn clone(self: *Doc) !*Doc {
        var item_map = std.HashMap(*item.Item, *item.Item, item.ItemHashContext, 80).init(self.allocator);
        defer item_map.deinit();
        item_map.ensureTotalCapacity(self.items);
        var it = self.iter();
        var head: ?*item.Item = null;
        while (it.next()) |curr_item| {
            const new_item = try curr_item.clone();
            try item_map.put(curr_item, new_item);
            if (head == null) head = new_item;
        }
        var item_it = item_map.keyIterator();
        while (item_it.next()) |curr_item| {
            var new_item = item_map.get(curr_item.*);
            if (new_item.?.left) |left| {
                new_item.?.left = item_map.get(left);
            }
            if (new_item.?.right) |right| {
                new_item.?.right = item_map.get(right);
            }
        }
        return try Doc.withHead(self.allocator, head);
    }

    /// Returns ArrayList of u8 containing all content inside doc. Caller responsible for calling ArrayList.deinit()
    pub fn toString(self: *Doc) !std.ArrayList(u8) {
        var buf = try std.ArrayList(u8).initCapacity(self.allocator, self.len);
        var it = self.iter();
        while (it.next()) |curr_item| {
            try buf.appendSlice(self.allocator, curr_item.content);
        }
        return buf;
    }

    /// Gets item given item id
    fn getItem(self: *Doc, id: item.ItemId) ?*item.Item {
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.id.clientId == id.clientId and curr_item.id.seqId >= id.seqId and curr_item.id.seqId + curr_item.content.len <= id.seqId) {
                return curr_item;
            }
        }
        return null;
    }

    /// Finds position in doc, will split items to create position
    fn findPosition(self: *Doc, index: usize) !*item.Item {
        var remaining = index;
        var last: *item.Item = self.head;
        var it = self.iter();
        while (it.next()) |currItem| {
            if (remaining <= 0) {
                break;
            }
            if (!currItem.isDeleted and currItem.content.len != 0) {
                if (currItem.content.len > remaining) {
                    last = try currItem.splice(currItem, remaining);
                    remaining -= currItem.content.len;
                    self.items += 1;
                    continue;
                }
                remaining -= currItem.content.len;
            }
            last = currItem;
        }
        return last;
    }

    /// Gets last item in doc for given clientId
    fn getLastItem(self: *Doc, clientId: usize) ?*item.Item {
        var last_item: ?*item.Item = null;
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.id.clientId == clientId) {
                if (last_item == null) {
                    last_item = curr_item;
                }
                if (curr_item.id.seqId > last_item.?.id.seqId) {
                    last_item = curr_item;
                }
            }
        }
        return last_item;
    }

    /// Gets next sequence id in doc for given clientId
    fn getNextSeqId(self: *Doc, clientId: usize) usize {
        const last_item = self.getLastItem(clientId);
        return if (last_item) |found_last_item| found_last_item.id.seqId + found_last_item.content.len else 1;
    }

    /// Check if we can two items on insertion
    fn canCompact(self: *Doc, clientId: usize, seqId: usize, left: *item.Item) bool {
        _ = self;
        return !left.isDeleted and left.id.clientId == clientId and left.id.seqId + left.content.len == seqId;
    }

    /// Inserts new item at index with clientId, splitting existing items when needed
    pub fn insert(self: *Doc, clientId: usize, index: usize, value: []const u8) !void {
        const seqId = self.getNextSeqId(clientId);
        var pos = try self.findPosition(index);
        if (self.canCompact(clientId, seqId, pos)) {
            const curr_content = pos.content;
            pos.content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ curr_content, value });
            if (pos.allocatedContent) {
                self.allocator.free(curr_content);
            }
            pos.allocatedContent = true;
            self.len += value.len;
            return;
        }
        const origin_right = if (pos.right) |right| right.id else null;
        const new_item = try item.Item.init(item.ItemId{ .clientId = clientId, .seqId = seqId }, pos.id, origin_right, pos, pos.right, value, false, self.allocator, &item.spliceStringItem, false);
        if (new_item.right) |right_item| right_item.left = new_item;
        pos.right = new_item;
        self.items += 1;
        self.len += value.len;
    }

    /// Marks index for deletion
    pub fn delete(self: *Doc, index: usize, len: usize) !void {
        const pos = try self.findPosition(index);
        var remaining = len;
        var o = pos.right;
        while (remaining > 0 and o != null) {
            if (o.?.isDeleted) {
                continue;
            }
            if (o.?.content.len > remaining) {
                _ = try o.?.splice(o.?, remaining);
            }
            remaining -= o.?.content.len;
            o.?.content = "";
            o = o.?.right;
            self.items -= 1;
        }
        self.len -= len - remaining;
    }

    /// Main conflict resolution, finds insert position given originLeft and originRight pointers. preceedingItems should contain all ItemIds before originLeft in document
    fn findInsertPosition(self: *Doc, block: *item.Item, origin_left: *item.Item, origin_right: ?*item.Item, preceeding_items: *item.ItemIdSet) ?*item.Item {
        var scanning = false;
        const right_id = if (origin_right) |o_r| o_r.id else null;
        const left_id = origin_left.id;
        var o = if (!left_id.eql(item.HeadItemId)) origin_left.right else self.head;
        var dst = if (!left_id.eql(item.HeadItemId)) origin_left.right else self.head;
        const client_id = block.id.clientId;
        while (true) {
            dst = if (scanning) dst else o;
            if (o == null or o.?.id.eql(right_id)) break;
            const o_left = o.?.originLeft;
            const o_right = o.?.originRight;
            const o_client_id = o.?.id.clientId;
            if (preceeding_items.contains(o_left) or (left_id.eql(o_left) and ((o_right == null and right_id == null) or right_id.?.eql(o_right)) and client_id <= o_client_id)) {
                break;
            }
            scanning = if (left_id.eql(o_left)) client_id <= o_client_id else scanning;
            o = o.?.right;
        }
        return dst;
    }

    /// Integrates new item into doc
    fn integrate(self: *Doc, new_item: *item.Item) !void {
        const client_id = new_item.id.clientId;
        const seq_id = new_item.id.seqId;
        var last = self.getLastItem(client_id);
        const next = if (last) |found_last| found_last.id.seqId + found_last.content.len else 1;
        if (next != seq_id) {
            if (last != null and seq_id < last.?.id.seqId + last.?.content.len) {
                // Found split in content, splice now
                _ = try last.?.splice(last.?, seq_id - last.?.id.seqId);
                self.items += 1;
                new_item.deinit();
                return;
            } else {
                return error.MissingOperation;
            }
        }
        if (self.head.right == null) {
            // inserting at head
            self.head.right = new_item;
            new_item.left = self.head;
            self.len += new_item.content.len;
            self.items += 1;
            return;
        }
        var left: *item.Item = self.head;
        var right: ?*item.Item = null;
        var it = self.iter();
        // Finding the preceeding items and storing them in a hash map is what takes the most amount of time in this function
        // Unusre of how to optimize HashMap.put(), and unsure of another structure that would be significantt
        var preceedingItems = item.ItemIdSet.init(self.allocator);
        defer preceedingItems.deinit();
        try preceedingItems.ensureTotalCapacity(self.items + 100);
        while (it.next()) |curr_item| {
            if ((left != self.head or new_item.originLeft.eql(self.head.id)) and (right != null or new_item.originRight == null)) {
                break;
            }
            if (curr_item.id.eql(new_item.originLeft)) {
                left = curr_item;
            }
            if (left == self.head) {
                try preceedingItems.put(curr_item.id, {});
            }
            if (curr_item.id.eql(new_item.originRight)) {
                right = curr_item;
            }
        }
        const find_preceeding = std.time.milliTimestamp();
        _ = find_preceeding;
        if (left.right == null and right == null) {
            // appending to end of list
            left.right = new_item;
            new_item.left = left;
            new_item.right = null;
            self.len += new_item.content.len;
            self.items += 1;
            return;
        }
        const i = self.findInsertPosition(new_item, left, right, &preceedingItems);
        new_item.right = i;
        if (i) |i_it| {
            new_item.left = i_it.left;
            if (new_item.left) |left_it| left_it.right = new_item;
            i_it.left = new_item;
        }
        self.len += new_item.content.len;
        self.items += 1;
    }

    /// Merge other doc into this doc. Copies all items from other doc
    pub fn merge(self: *Doc, other: *Doc) !void {
        var seen = item.ItemIdSet.init(self.allocator);
        try seen.ensureTotalCapacity(self.items + other.items);
        defer seen.deinit();
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item != self.head and curr_item.content.len == 0) {
                curr_item.isDeleted = true;
            }
            if (!curr_item.isDeleted) {
                try seen.put(curr_item.id, {});
            }
        }
        var blocks = try std.ArrayList(*item.Item).initCapacity(self.allocator, other.items);
        defer blocks.deinit(self.allocator);
        var other_it = other.iter();
        while (other_it.next()) |curr_item| {
            if (!seen.contains(curr_item.id)) {
                try blocks.append(self.allocator, curr_item);
            }
        }
        var remaining = blocks.items.len;
        while (remaining > 0) {
            for (blocks.items) |block| {
                const canInsert = !seen.contains(block.id) and seen.contains(block.originLeft) and (block.originRight == null or seen.contains(block.originRight.?));
                if (canInsert) {
                    const new_item = try block.clone();
                    try self.integrate(new_item);
                    try seen.put(block.id, {});
                    remaining -= 1;
                }
            }
        }
    }

    /// Gets current version map (clientId => max(seqId)) for doc
    fn version(self: *Doc) !DocVersion {
        var version_map = std.AutoHashMap(usize, usize).init(self.allocator);
        var it = self.iter();
        while (it.next()) |curr_item| {
            const max_seq = (try version_map.getOrPutValue(curr_item.id.clientId, curr_item.id.seqId)).value_ptr;
            if (curr_item.id.seqId > max_seq.*) {
                try version_map.put(curr_item.id.clientId, curr_item.id.seqId);
            }
        }
        return version_map;
    }

    /// Generates DocDelta for this document based off proivded DocVersion
    pub fn getUpdate(self: *Doc, other_version: DocVersion) !*DocDelta {
        var delta_head: ?*item.Item = null;
        var curr_delta: ?*item.Item = null;
        var tombstones = item.ItemIdSet.init(self.allocator);
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (!other_version.contains(curr_item.id.clientId) or curr_item.id.seqId > other_version.get(curr_item.id.clientId) orelse 0) {
                if (delta_head == null) {
                    delta_head = try curr_item.clone();
                    curr_delta = delta_head;
                    curr_delta.?.right = null;
                    curr_delta.?.left = null;
                } else {
                    curr_delta.?.right = try curr_item.clone();
                    const old_delta = curr_delta;
                    curr_delta = curr_delta.?.right;
                    curr_delta.?.left = old_delta;
                }
            }
            if (curr_item.isDeleted) {
                try tombstones.put(curr_item.id, {});
            }
        }
        return DocDelta.init(delta_head, tombstones, self.allocator);
    }

    /// Generates DocDelta between this doc and provided other doc. Caller responsible for calling DocDelta.deinit()
    pub fn delta(self: *Doc, doc: *Doc) !*DocDelta {
        var curr_version = try self.version();
        defer curr_version.deinit();
        return doc.getUpdate(curr_version);
    }

    /// Merges a DocDelta into this doc, copying all items
    pub fn mergeDelta(self: *Doc, doc_delta: *DocDelta) !void {
        var head = try Doc.createHeadItem(self.allocator);
        if (doc_delta.delta) |d| {
            const null_head = head;
            head = d;
            null_head.deinit();
        }
        var delta_doc = try Doc.withHead(self.allocator, head);
        defer delta_doc.deinitNoItems();
        try self.merge(delta_doc);
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (!curr_item.isDeleted and doc_delta.tombstones.contains(curr_item.id)) {
                curr_item.content = "";
            }
        }
    }

    const DocData = struct {
        item_map: std.StringArrayHashMap([]const u8),
        head: ?[]const u8,
        len: usize,
        items: u32,
        allocator: std.mem.Allocator,
        allocated: bool,

        const InnerData = struct {
            item_map: std.json.ArrayHashMap([]const u8),
            head: ?[]const u8,
            len: usize,
            items: u32,
        };
        pub fn fromDoc(doc: *Doc, allocator: std.mem.Allocator) !*DocData {
            const doc_data = try allocator.create(DocData);
            var item_map = std.StringArrayHashMap([]const u8).init(allocator);
            var doc_iter = doc.iter();
            while (doc_iter.next()) |doc_item| {
                try item_map.put(try doc_item.id.fmt(allocator), try doc_item.serialize());
            }
            doc_data.* = .{
                .allocator = allocator,
                .item_map = item_map,
                .head = try doc.head.id.fmt(allocator),
                .items = doc.items,
                .len = doc.len,
                .allocated = true,
            };
            return doc_data;
        }

        pub fn toDoc(self: *DocData) !*Doc {
            var item_data_map = std.HashMap(
                item.ItemId,
                item.Item.ItemData,
                item.ItemIdHashContext,
                80,
            ).init(self.allocator);
            defer item_data_map.deinit();
            for (self.item_map.keys()) |id| {
                const parsed = try std.json.parseFromSlice(item.Item.ItemData, self.allocator, self.item_map.get(id).?, .{});
                defer parsed.deinit();
                try item_data_map.put(try item.ItemId.fromString(id), parsed.value);
            }
            var item_map = item.ItemIdMap.init(self.allocator);
            defer item_map.deinit();
            var item_data_map_iter = item_data_map.keyIterator();
            while (item_data_map_iter.next()) |id| {
                const new_item = try item.Item.fromData(item_data_map.get(id.*).?, self.allocator);
                try item_map.put(id.*, new_item);
            }
            var item_map_iter = item_map.keyIterator();
            while (item_map_iter.next()) |id| {
                const data = item_data_map.get(id.*).?;
                if (data.right != null) {
                    const right = item_map.get(data.right.?).?;
                    const curr = item_map.get(id.*).?;
                    curr.right = right;
                    right.left = curr;
                }
            }
            const head_id = if (self.head != null) try item.ItemId.fromString(self.head.?) else item.HeadItemId;
            return Doc.withHead(self.allocator, item_map.get(head_id).?);
        }

        pub fn deinit(self: *DocData) void {
            if (self.allocated) {
                for (self.item_map.keys()) |key| {
                    self.allocator.free(self.item_map.get(key).?);
                    self.allocator.free(key);
                }
                if (self.head != null) self.allocator.free(self.head.?);
            }
            self.item_map.deinit();
            self.allocator.destroy(self);
        }

        pub fn onlyData(self: *DocData) InnerData {
            const item_map = std.json.ArrayHashMap([]const u8){ .map = self.item_map.unmanaged };
            return .{
                .item_map = item_map,
                .head = self.head,
                .len = self.len,
                .items = self.items,
            };
        }

        pub fn fromInnerData(data: InnerData, allocator: std.mem.Allocator) !*DocData {
            const new_data = try allocator.create(DocData);
            var item_map = std.StringArrayHashMap([]const u8).init(allocator);
            for (data.item_map.map.keys()) |key| {
                try item_map.put(key, data.item_map.map.get(key).?);
            }
            new_data.* = .{
                .allocator = allocator,
                .item_map = item_map,
                .head = data.head,
                .len = data.len,
                .items = data.items,
                .allocated = false,
            };
            return new_data;
        }
    };

    pub fn serialize(self: *Doc) ![]const u8 {
        const doc_data = try DocData.fromDoc(self, self.allocator);
        defer doc_data.deinit();
        var buf = std.io.Writer.Allocating.init(self.allocator);
        defer buf.deinit();
        const formatter = std.json.fmt(doc_data.onlyData(), .{});
        try formatter.format(&buf.writer);
        return try buf.toOwnedSlice();
    }

    pub fn deserialize(value: []const u8, allocator: std.mem.Allocator) !*Doc {
        const parsed = try std.json.parseFromSlice(
            DocData.InnerData,
            allocator,
            value,
            .{},
        );
        defer parsed.deinit();
        const doc_data = try DocData.fromInnerData(
            parsed.value,
            allocator,
        );
        defer doc_data.deinit();
        return try doc_data.toDoc();
    }
};

test "Create doc test" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello");
    var result1 = try doc.toString();
    defer result1.deinit(testing.allocator);
    try expect(std.mem.eql(u8, result1.items, "Hello"));
    try doc.insert(1, 3, "p");
    var result2 = try doc.toString();
    defer result2.deinit(testing.allocator);
    try expect(std.mem.eql(u8, result2.items, "Helplo"));
}

test "Delete text test" {
    var doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello World");
    var result1 = try doc.toString();
    defer result1.deinit(testing.allocator);
    try expect(std.mem.eql(u8, result1.items, "Hello World"));
    try doc.delete(1, 3);
    var result2 = try doc.toString();
    defer result2.deinit(testing.allocator);
    try expect(std.mem.eql(u8, result2.items, "Ho World"));
}

test "Merge docs test" {
    var doc1 = try Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 2, "p");
    try doc1.insert(1, 2, "r");

    try doc1.merge(doc2);
    try doc2.merge(doc1);
    var doc1_res = try doc1.toString();
    defer doc1_res.deinit(testing.allocator);
    var doc2_res = try doc2.toString();
    defer doc2_res.deinit(testing.allocator);

    try expect(std.mem.eql(u8, doc1_res.items, "Herpllo"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}

test "delta merge docs test" {
    var doc1 = try Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 1, "p");
    try doc1.insert(1, 1, "r");
    var doc1_delta = try doc1.delta(doc2);
    defer doc1_delta.deinit();
    var doc2_delta = try doc2.delta(doc1);
    defer doc2_delta.deinit();
    try expect(doc2_delta.delta.?.right == null);
    try expect(doc1_delta.delta.?.right == null);
    try doc1.mergeDelta(doc1_delta);
    try doc2.mergeDelta(doc2_delta);
    var doc1_res = try doc1.toString();
    defer doc1_res.deinit(testing.allocator);
    var doc2_res = try doc2.toString();
    defer doc2_res.deinit(testing.allocator);
    try expect(std.mem.eql(u8, doc1_res.items, "Hrpello"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}

test "delta serialize" {
    var doc1 = try Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 1, "p");
    try doc1.insert(1, 1, "r");
    var doc1_delta = try doc1.delta(doc2);
    defer doc1_delta.deinit();
    const doc1_serialized = try doc1_delta.serialize();
    defer testing.allocator.free(doc1_serialized);
    const doc1_deserialized = try DocDelta.deserialize(doc1_serialized, testing.allocator);
    defer doc1_deserialized.deinit();
    var doc2_delta = try doc2.delta(doc1);
    defer doc2_delta.deinit();
    const doc2_serialized = try doc2_delta.serialize();
    defer testing.allocator.free(doc2_serialized);
    const doc2_deserialized = try DocDelta.deserialize(doc2_serialized, testing.allocator);
    defer doc2_deserialized.deinit();
    try expect(doc2_deserialized.delta.?.right == null);
    try expect(doc1_deserialized.delta.?.right == null);
    try doc1.mergeDelta(doc1_deserialized);
    try doc2.mergeDelta(doc2_deserialized);
    var doc1_res = try doc1.toString();
    defer doc1_res.deinit(testing.allocator);
    var doc2_res = try doc2.toString();
    defer doc2_res.deinit(testing.allocator);
    try expect(std.mem.eql(u8, doc1_res.items, "Hrpello"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}

fn generateString(n: usize, allocator: std.mem.Allocator) ![]const u8 {
    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();
    var res = try allocator.alloc(u8, n);
    for (res[0..], 0..) |_, i| {
        res[i] = rng.intRangeAtMost(u8, 33, 126);
    }
    return res;
}

fn bench(str: []const u8, allocator: std.mem.Allocator) !std.meta.Tuple(&.{ *Doc, *Doc, *Doc }) {
    var doc1 = try Doc.init(allocator);
    var doc2 = try Doc.init(allocator);
    var doc3 = try Doc.init(allocator);
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        try doc1.insert(1, i, str[i .. i + 1]);
    }
    try doc2.merge(doc1);
    var delta = try doc3.delta(doc1);
    defer delta.deinit();
    try doc3.mergeDelta(delta);
    return .{ doc1, doc2, doc3 };
}

test "large doc operation memory leak test" {
    const str = try generateString(2, testing.allocator);
    defer testing.allocator.free(str);
    const result = try bench(str, testing.allocator);
    defer result[0].deinit();
    defer result[1].deinit();
    defer result[2].deinit();
    var res1 = try result[0].toString();
    defer res1.deinit(testing.allocator);
    try expect(std.mem.eql(u8, res1.items, str));
    var res2 = try result[1].toString();
    defer res2.deinit(testing.allocator);
    try expect(std.mem.eql(u8, res1.items, res2.items));
    var res3 = try result[2].toString();
    defer res3.deinit(testing.allocator);
    try expect(std.mem.eql(u8, res3.items, res1.items));
}

test "serialize document" {
    const doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello World");
    const serialized = try doc.serialize();
    defer testing.allocator.free(serialized);
    std.debug.print("{s}", .{serialized});
    const deserialized = try Doc.deserialize(serialized, testing.allocator);
    defer deserialized.deinit();
    try expect(deserialized.eql(doc));

    const doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    const str = try generateString(2000, testing.allocator);
    defer testing.allocator.free(str);
    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        try doc2.insert(1, i, str[i .. i + 1]);
    }
    const serialized2 = try doc2.serialize();
    defer testing.allocator.free(serialized2);

    const deserialized2 = try Doc.deserialize(serialized2, testing.allocator);
    defer deserialized2.deinit();
    try expect(deserialized2.eql(doc2));
    try expect(!deserialized2.eql(doc));
}

test "compaction" {
    const doc = try Doc.init(testing.allocator);
    defer doc.deinit();
    const str = try generateString(2000, testing.allocator);
    defer testing.allocator.free(str);

    var i: usize = 0;
    while (i < str.len) : (i += 1) {
        try doc.insert(1, i, str[i .. i + 1]);
    }

    var res1 = try doc.toString();
    defer res1.deinit(testing.allocator);
    try expect(std.mem.eql(u8, str, res1.items));
    try expect(doc.items == 2);

    const str2 = try generateString(2000, testing.allocator);

    var prng = std.Random.DefaultPrng.init(0);
    const rng = prng.random();

    const doc2 = try Doc.init(testing.allocator);
    defer doc2.deinit();
    defer testing.allocator.free(str2);
    var expected_str = try std.ArrayList(u8).initCapacity(testing.allocator, str2.len);
    defer expected_str.deinit(testing.allocator);
    i = 0;
    while (i < str2.len) : (i += 1) {
        const idx = rng.intRangeAtMost(usize, 0, i);
        try doc2.insert(1, idx, str2[i .. i + 1]);
        try expected_str.insert(testing.allocator, idx, str2[i .. i + 1][0]);
    }

    // should hopefully not run into the situation where we always insert at the end of the document
    try expect(doc2.items > 2);
    var res2 = try doc2.toString();
    defer res2.deinit(testing.allocator);
    try expect(std.mem.eql(u8, res2.items, expected_str.items));
}
