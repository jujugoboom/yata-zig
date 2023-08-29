const item = @import("item.zig");
const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

/// Possible merge errors
const MergeError = error{ MissingOperation, MissingParent };

/// Struct to hold delta between two docs. Generated through Doc.delta()
const DocDelta = struct {
    delta: ?*item.Item,
    tombstones: std.AutoHashMap(item.ItemId, void),
    pub fn deinit(self: *DocDelta) void {
        self.tombstones.deinit();
        var it = DocIterator{ .curr_item = self.delta };
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
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

/// Main doc struct. Contains all logic for YATA CRDT and handles all item creation
pub const Doc = struct {
    head: ?*item.Item,
    allocator: std.mem.Allocator,
    /// Inits new doc with supplied allocator. Caller is responsible for calling Doc.deinit()
    pub fn init(allocator: std.mem.Allocator) Doc {
        return Doc{ .head = null, .allocator = allocator };
    }

    /// Basic wrapper around creating a duplicate of a doc
    fn withHead(allocator: std.mem.Allocator, head: ?*item.Item) Doc {
        return Doc{ .head = head, .allocator = allocator };
    }

    /// Doc destructor
    pub fn deinit(self: *Doc) void {
        var it = self.iter();
        while (it.next()) |curr_item| {
            curr_item.deinit();
        }
    }

    /// Creates DocIterator for doc
    pub fn iter(self: Doc) DocIterator {
        return DocIterator{ .curr_item = self.head };
    }

    /// Clones self into a new doc. Allocates new doc with existing allocator, caller is responsible for calling Doc.deinit() on returned doc.
    pub fn clone(self: *Doc) !Doc {
        var item_map = std.AutoHashMap(*item.Item, *item.Item).init(self.allocator);
        defer item_map.deinit();
        var it = self.iter();
        var head: ?*item.Item = null;
        var alloc_content = std.ArrayList([]const u8).init(self.allocator);
        while (it.next()) |curr_item| {
            var new_item = try curr_item.clone();
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
        return Doc.withHead(self.allocator, head, alloc_content);
    }

    /// Returns ArrayList of u8 containing all content inside doc. Caller responsible for calling ArrayList.deinit()
    pub fn toString(self: Doc) !std.ArrayList(u8) {
        var buf = std.ArrayList(u8).init(self.allocator);
        if (self.head == null) {
            return buf;
        }
        var it = self.iter();
        while (it.next()) |curr_item| {
            try buf.appendSlice(curr_item.content);
        }
        return buf;
    }

    /// Gets item given item id
    fn getItem(self: Doc, id: item.ItemId) ?*item.Item {
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.id.clientId == id.clientId and curr_item.id.seqId >= id.seqId and curr_item.id.seqId + curr_item.content.len <= id.seqId) {
                return curr_item;
            }
        }
        return null;
    }

    /// Finds position in doc, will split items to create position
    fn findPosition(self: *Doc, index: usize) !?*item.Item {
        var remaining = index;
        var last: ?*item.Item = self.head;
        var it = self.iter();
        while (it.next()) |currItem| {
            if (remaining <= 0) {
                break;
            }
            if (!currItem.isDeleted and currItem.content.len != 0) {
                if (currItem.content.len > remaining) {
                    last = try currItem.splice(currItem, remaining);
                    remaining -= currItem.content.len;
                    continue;
                }
                remaining -= currItem.content.len;
            }
            last = currItem;
        }
        return last;
    }

    /// Gets next sequence id in doc for given clientId
    fn getNextSeqId(self: Doc, clientId: usize) usize {
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
        return if (last_item) |found_last_item| found_last_item.id.seqId + found_last_item.content.len else 1;
    }

    /// Gets last item in doc for given clientId
    fn getLastItem(self: Doc, clientId: usize) ?*item.Item {
        var last_item: ?*item.Item = null;
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (last_item == null and curr_item.id.clientId == clientId) {
                last_item = curr_item;
            }
            if (curr_item.id.clientId == clientId and curr_item.id.seqId > last_item.?.id.seqId) {
                last_item = curr_item;
            }
        }
        return last_item;
    }

    /// Inserts new item at index with clientId, splitting existing items when needed
    pub fn insert(self: *Doc, clientId: usize, index: usize, value: []const u8) !void {
        const seqId = self.getNextSeqId(clientId);
        var new_item = try item.Item.init(item.ItemId{ .clientId = clientId, .seqId = seqId }, null, null, null, null, value, false, self.allocator, &item.spliceStringItem, false);
        if (self.head == null) {
            self.head = new_item;
            return;
        }
        var pos = try self.findPosition(index);
        new_item.originLeft = pos.?.id;
        new_item.originRight = if (pos.?.right) |right| right.id else null;
        new_item.left = pos;
        new_item.right = pos.?.right;
        if (new_item.right) |right_item| right_item.left = new_item;
        pos.?.right = new_item;
    }

    /// Marks index for deletion
    pub fn delete(self: *Doc, index: usize, len: usize) !void {
        const pos = try self.findPosition(index);
        if (pos == null) {
            return;
        }
        var remaining = len;
        var o = pos.?.right;
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
        }
    }

    /// Main conflict resolution, finds insert position given originLeft and originRight pointers. preceedingItems should contain all ItemIds before originLeft in document
    fn findInsertPosition(self: *Doc, block: *item.Item, originLeft: ?*item.Item, originRight: ?*item.Item, preceedingItems: *std.AutoHashMap(item.ItemId, void)) ?*item.Item {
        var scanning = false;
        const left_id = if (originLeft) |left_it| left_it.id else item.InvalidItemId;
        const right_id = if (originRight) |right_it| right_it.id else item.InvalidItemId;
        var o = if (originLeft) |left_it| left_it.right else self.head;
        var dst = if (originLeft) |left_it| left_it.right else self.head;
        const client_id = block.id.clientId;
        while (true) {
            dst = if (scanning) dst else o;
            if (o == null or right_id.eql(o.?.id)) break;
            const o_left = o.?.originLeft;
            const o_right = o.?.originRight;
            const o_client_id = o.?.id.clientId;
            if (preceedingItems.contains(o_left orelse item.InvalidItemId) or (left_id.eql(o_left orelse item.InvalidItemId) and right_id.eql(o_right orelse item.InvalidItemId) and client_id <= o_client_id)) {
                break;
            }
            scanning = if (left_id.eql(o_left orelse item.InvalidItemId)) client_id <= o_client_id else scanning;
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
                _ = try self.findPosition(new_item.originLeft.?.seqId);
                new_item.deinit();
                return;
            } else {
                return error.MissingOperation;
            }
        }
        if (self.head == null) {
            // First element
            self.head = new_item;
            return;
        }
        var left: ?*item.Item = null;
        var right: ?*item.Item = null;
        var it = self.iter();
        var preceedingItems = std.AutoHashMap(item.ItemId, void).init(self.allocator);
        defer preceedingItems.deinit();
        while (it.next()) |curr_item| {
            if (curr_item.id.eql(new_item.originLeft orelse item.InvalidItemId)) {
                left = curr_item;
            }
            if (left == null) {
                try preceedingItems.put(curr_item.id, {});
            }
            if (std.meta.eql(curr_item.id, new_item.originRight orelse item.InvalidItemId)) {
                right = curr_item;
            }
        }
        const i = self.findInsertPosition(new_item, left, right, &preceedingItems);
        new_item.right = i;
        new_item.left = null;
        if (i) |i_it| {
            new_item.left = i_it.left;
            if (new_item.left) |left_it| left_it.right = new_item;
            i_it.left = new_item;
        }
    }

    /// Merge other doc into this doc. Copies all items from other doc
    pub fn merge(self: *Doc, other: Doc) !void {
        var seen = std.AutoHashMap(item.ItemId, void).init(self.allocator);
        defer seen.deinit();
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (curr_item.content.len == 0) {
                curr_item.isDeleted = true;
            }
            if (!curr_item.isDeleted) {
                try seen.put(curr_item.id, {});
            }
        }
        var blocks = std.ArrayList(*item.Item).init(self.allocator);
        defer blocks.deinit();
        var other_it = other.iter();
        while (other_it.next()) |curr_item| {
            if (!seen.contains(curr_item.id)) {
                try blocks.append(curr_item);
            }
        }
        var remaining = blocks.items.len;
        while (remaining > 0) {
            for (blocks.items) |block| {
                const canInsert = !seen.contains(block.id) and (block.originLeft == null or seen.contains(block.originLeft.?)) and (block.originRight == null or seen.contains(block.originRight.?));
                if (canInsert) {
                    var new_item = try block.clone();
                    try self.integrate(new_item);
                    try seen.put(block.id, {});
                    remaining -= 1;
                }
            }
        }
    }

    /// Gets current version map (clientId => max(seqId)) for doc
    fn version(self: Doc) !std.AutoHashMap(usize, usize) {
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

    /// Generates DocDelta between this doc and provided other doc. Caller responsible for calling DocDelta.deinit()
    pub fn delta(self: Doc, doc: Doc) !DocDelta {
        var delta_head: ?*item.Item = null;
        var curr_delta: ?*item.Item = null;
        var tombstones = std.AutoHashMap(item.ItemId, void).init(self.allocator);
        var curr_version = try self.version();
        defer curr_version.deinit();
        var it = doc.iter();
        while (it.next()) |curr_item| {
            if (!curr_version.contains(curr_item.id.clientId) or curr_item.id.seqId > curr_version.get(curr_item.id.clientId) orelse 0) {
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
        return DocDelta{ .delta = delta_head, .tombstones = tombstones };
    }

    /// Merges a DocDelta into this doc, copying all items
    pub fn mergeDelta(self: *Doc, doc_delta: *DocDelta) !void {
        var delta_doc = Doc.withHead(self.allocator, doc_delta.delta);
        try self.merge(delta_doc);
        var it = self.iter();
        while (it.next()) |curr_item| {
            if (!curr_item.isDeleted and doc_delta.tombstones.contains(curr_item.id)) {
                curr_item.content = "";
            }
        }
    }
};

test "Create doc test" {
    var doc = Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello");
    const result1 = try doc.toString();
    defer result1.deinit();
    try expect(std.mem.eql(u8, result1.items, "Hello"));
    try doc.insert(1, 3, "p");
    const result2 = try doc.toString();
    defer result2.deinit();
    try expect(std.mem.eql(u8, result2.items, "Helplo"));
}

test "Delete text test" {
    var doc = Doc.init(testing.allocator);
    defer doc.deinit();
    try doc.insert(1, 0, "Hello World");
    const result1 = try doc.toString();
    defer result1.deinit();
    try expect(std.mem.eql(u8, result1.items, "Hello World"));
    try doc.delete(1, 3);
    const result2 = try doc.toString();
    defer result2.deinit();
    try expect(std.mem.eql(u8, result2.items, "Ho World"));
}

test "Merge docs test" {
    var doc1 = Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = Doc.init(testing.allocator);
    defer doc2.deinit();
    try doc2.insert(1, 0, "Hello");
    try doc2.insert(2, 2, "p");
    try doc1.insert(1, 2, "r");

    try doc1.merge(doc2);
    try doc2.merge(doc1);
    const doc1_res = try doc1.toString();
    defer doc1_res.deinit();
    const doc2_res = try doc2.toString();
    defer doc2_res.deinit();

    try expect(std.mem.eql(u8, doc1_res.items, "Herpllo"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}

test "delta merge docs test" {
    var doc1 = Doc.init(testing.allocator);
    defer doc1.deinit();
    try doc1.insert(1, 0, "Hello");

    var doc2 = Doc.init(testing.allocator);
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
    try doc1.mergeDelta(&doc1_delta);
    try doc2.mergeDelta(&doc2_delta);
    const doc1_res = try doc1.toString();
    defer doc1_res.deinit();
    const doc2_res = try doc2.toString();
    defer doc2_res.deinit();
    try expect(std.mem.eql(u8, doc1_res.items, "Hrpello"));
    try expect(std.mem.eql(u8, doc1_res.items, doc2_res.items));
}
