const std = @import("std");
const testing = std.testing;
const irc = @import("irc.zig");
const Command = irc.Command;
const Client = @import("Client.zig");

/// an irc message
pub const Message = @This();

client: *Client,
src: []const u8,
tags: ?[]const u8,
source: ?[]const u8,
command: Command,
params: ?[]const u8,

pub const ParamIterator = struct {
    params: ?[]const u8,
    index: usize = 0,

    pub fn next(self: *ParamIterator) ?[]const u8 {
        const params = self.params orelse return null;
        if (self.index >= params.len) return null;

        // consume leading whitespace
        while (self.index < params.len) {
            if (params[self.index] != ' ') break;
            self.index += 1;
        }

        const start = self.index;
        if (start >= params.len) return null;

        // If our first byte is a ':', we return the rest of the string as a
        // single param (or the empty string)
        if (params[start] == ':') {
            self.index = params.len;
            if (start == params.len - 1) {
                return "";
            }
            return params[start + 1 ..];
        }

        // Find the first index of space. If we don't have any, the reset of
        // the line is the last param
        self.index = std.mem.indexOfScalarPos(u8, params, self.index, ' ') orelse {
            defer self.index = params.len;
            return params[start..];
        };

        return params[start..self.index];
    }
};

pub fn init(src: []const u8, client: *Client) !Message {
    var i: usize = 0;
    const tags: ?[]const u8 = blk: {
        if (src[i] != '@') break :blk null;
        const n = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return error.InvalidMessage;
        const tags = src[i + 1 .. n];
        i = n;
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }
        break :blk tags;
    };

    const source: ?[]const u8 = blk: {
        if (src[i] != ':') break :blk null;
        const n = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return error.InvalidMessage;
        const source = src[i + 1 .. n];
        i = n;
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }
        break :blk source;
    };

    const n = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;

    const cmd = Command.parse(src[i..n]);

    i = n;

    // consume whitespace
    while (i < src.len) : (i += 1) {
        if (src[i] != ' ') break;
    }

    const params: ?[]const u8 = if (i == src.len) null else src[i..src.len];

    return .{
        .src = src,
        .tags = tags,
        .source = source,
        .command = cmd,
        .params = params,
        .client = client,
    };
}

pub fn deinit(msg: Message, alloc: std.mem.Allocator) void {
    alloc.free(msg.src);
}

pub fn paramIterator(msg: Message) ParamIterator {
    return .{ .params = msg.params };
}

test "simple message" {
    const msg = try Message.init("JOIN");

    try testing.expect(msg.tags == null);
    try testing.expect(msg.source == null);
    try testing.expectEqualStrings("JOIN", msg.command);
    try testing.expect(msg.params == null);
}

test "simple message with extra whitespace" {
    const msg = try Message.init("JOIN       ");

    try testing.expect(msg.tags == null);
    try testing.expect(msg.source == null);
    try testing.expectEqualStrings("JOIN", msg.command);
    try testing.expect(msg.params == null);
}

test "well formed message with tags, source, params" {
    const msg = try Message.init("@key=value :example.chat JOIN abc def");

    try testing.expectEqualStrings("key=value", msg.tags.?);
    try testing.expectEqualStrings("example.chat", msg.source.?);
    try testing.expectEqualStrings("JOIN", msg.command);
    try testing.expectEqualStrings("abc def", msg.params.?);
}

test "message with tags, source, params and extra whitespace" {
    const msg = try Message.init("@key=value   :example.chat    JOIN    abc def");

    try testing.expectEqualStrings("key=value", msg.tags.?);
    try testing.expectEqualStrings("example.chat", msg.source.?);
    try testing.expectEqualStrings("JOIN", msg.command);
    try testing.expectEqualStrings("abc def", msg.params.?);
}

test "param iterator: simple list" {
    var iter: Message.ParamIterator = .{ .params = "a b c" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("a", param),
            1 => try testing.expectEqualStrings("b", param),
            2 => try testing.expectEqualStrings("c", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: trailing colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :sasl multi-prefix" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("sasl multi-prefix", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon and leading colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS ::)" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings(":)", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}
