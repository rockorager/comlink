const std = @import("std");
const vaxis = @import("vaxis");
const irc = @import("irc.zig");

const mem = std.mem;

const ColorState = enum {
    ground,
    fg,
    bg,
};

const LinkState = enum {
    h,
    t1,
    t2,
    p,
    s,
    colon,
    slash,
    consume,
};

/// generate vaxis.Segments for the message content
pub fn message(segments: *std.ArrayList(vaxis.Segment), user: *const irc.User, msg: irc.Message) !void {
    var iter = msg.paramIterator();
    // skip the first param, this is the receiver of the message
    _ = iter.next() orelse return error.InvalidMessage;
    const content = iter.next() orelse return error.InvalidMessage;

    var start: usize = 0;
    var i: usize = 0;
    var style: vaxis.Style = .{};
    while (i < content.len) : (i += 1) {
        const b = content[i];
        switch (b) {
            0x01 => {
                if (i == 0 and
                    content.len > 7 and
                    mem.startsWith(u8, content[1..], "ACTION"))
                {
                    style.italic = true;
                    const user_style: vaxis.Style = .{
                        .fg = user.color,
                        .italic = true,
                    };
                    try segments.append(.{
                        .text = user.nick,
                        .style = user_style,
                    });
                    i += 6; // "ACTION"
                } else {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                start = i + 1;
            },
            0x02 => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                style.bold = !style.bold;
                start = i + 1;
            },
            0x03 => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                i += 1;
                var state: ColorState = .ground;
                var fg_idx: ?u8 = null;
                var bg_idx: ?u8 = null;
                while (i < content.len) : (i += 1) {
                    const d = content[i];
                    switch (state) {
                        .ground => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    state = .fg;
                                    fg_idx = d - '0';
                                },
                                else => {
                                    style.fg = .default;
                                    style.bg = .default;
                                    start = i;
                                    break;
                                },
                            }
                        },
                        .fg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const fg = fg_idx orelse 0;
                                    if (fg > 9) {
                                        style.fg = irc.toVaxisColor(fg);
                                        start = i;
                                        break;
                                    } else {
                                        fg_idx = fg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (fg_idx) |fg| {
                                        style.fg = irc.toVaxisColor(fg);
                                        start = i;
                                    }
                                    if (d == ',') state = .bg else break;
                                },
                            }
                        },
                        .bg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const bg = bg_idx orelse 0;
                                    if (i - start == 2) {
                                        style.bg = irc.toVaxisColor(bg);
                                        start = i;
                                        break;
                                    } else {
                                        bg_idx = bg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (bg_idx) |bg| {
                                        style.bg = irc.toVaxisColor(bg);
                                        start = i;
                                    }
                                    break;
                                },
                            }
                        },
                    }
                }
            },
            0x0F => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                style = .{};
                start = i + 1;
            },
            0x16 => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                style.reverse = !style.reverse;
                start = i + 1;
            },
            0x1D => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                style.italic = !style.italic;
                start = i + 1;
            },
            0x1E => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                style.strikethrough = !style.strikethrough;
                start = i + 1;
            },
            0x1F => {
                if (i > start) {
                    try segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }

                style.ul_style = if (style.ul_style == .off) .single else .off;
                start = i + 1;
            },
            else => {
                if (b == 'h') {
                    var state: LinkState = .h;
                    const h_start = i;
                    // consume until a space or EOF
                    i += 1;
                    while (i < content.len) : (i += 1) {
                        const b1 = content[i];
                        switch (state) {
                            .h => {
                                if (b1 == 't') state = .t1 else break;
                            },
                            .t1 => {
                                if (b1 == 't') state = .t2 else break;
                            },
                            .t2 => {
                                if (b1 == 'p') state = .p else break;
                            },
                            .p => {
                                if (b1 == 's')
                                    state = .s
                                else if (b1 == ':')
                                    state = .colon
                                else
                                    break;
                            },
                            .s => {
                                if (b1 == ':') state = .colon else break;
                            },
                            .colon => {
                                if (b1 == '/') state = .slash else break;
                            },
                            .slash => {
                                if (b1 == '/') {
                                    state = .consume;
                                    if (h_start > start) {
                                        try segments.append(.{
                                            .text = content[start..h_start],
                                            .style = style,
                                        });
                                    }
                                    start = h_start;
                                } else break;
                            },
                            .consume => {
                                switch (b1) {
                                    0x00...0x20, 0x7F => {
                                        try segments.append(.{
                                            .text = content[h_start..i],
                                            .style = .{
                                                .fg = .{ .index = 4 },
                                            },
                                            .link = .{
                                                .uri = content[h_start..i],
                                            },
                                        });
                                        start = i;
                                        // backup one
                                        i -= 1;
                                        break;
                                    },
                                    else => {
                                        if (i == content.len - 1) {
                                            try segments.append(.{
                                                .text = content[h_start..],
                                                .style = .{
                                                    .fg = .{ .index = 4 },
                                                },
                                                .link = .{
                                                    .uri = content[h_start..],
                                                },
                                            });
                                            return;
                                        }
                                    },
                                }
                            },
                        }
                    }
                }
            },
        }
    }
    if (start < i and start < content.len) {
        try segments.append(.{
            .text = content[start..],
            .style = style,
        });
    }
}

test "format.zig: no format" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{ .bytes = "PRIVMSG #comlink :foo" };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    try std.testing.expectEqual(1, list.items.len);
    const expected: vaxis.Segment = .{ .text = "foo" };
    try std.testing.expectEqualDeep(expected, list.items[0]);
}

test "format.zig: bold" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{ .bytes = "PRIVMSG #comlink :\x02foo\x02" };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    try std.testing.expectEqual(1, list.items.len);
    const expected: vaxis.Segment = .{ .text = "foo", .style = .{ .bold = true } };
    try std.testing.expectEqualDeep(expected, list.items[0]);
}

test "format.zig: italic" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{ .bytes = "PRIVMSG #comlink :\x1dfoo\x1d" };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    try std.testing.expectEqual(1, list.items.len);
    const expected: vaxis.Segment = .{ .text = "foo", .style = .{ .italic = true } };
    try std.testing.expectEqualDeep(expected, list.items[0]);
}

test "format.zig: strikethrough, reverse, underline" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{
        .bytes = "PRIVMSG #comlink :\x16foo\x16\x1Dbar\x1D\x1Ebaz\x1E\x1Ffoo\x1F",
    };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    const expected: []const vaxis.Segment = &.{
        .{ .text = "foo", .style = .{ .reverse = true } },
        .{ .text = "bar", .style = .{ .italic = true } },
        .{ .text = "baz", .style = .{ .strikethrough = true } },
        .{ .text = "foo", .style = .{ .ul_style = .single } },
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |seg, i| {
        try std.testing.expectEqualDeep(seg, list.items[i]);
    }
}

test "format.zig: format without closer" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{
        .bytes = "PRIVMSG #comlink :\x16foo\x16\x1Dbar\x1D\x1Ebaz\x1E\x1Ffoo",
    };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    const expected: []const vaxis.Segment = &.{
        .{ .text = "foo", .style = .{ .reverse = true } },
        .{ .text = "bar", .style = .{ .italic = true } },
        .{ .text = "baz", .style = .{ .strikethrough = true } },
        .{ .text = "foo", .style = .{ .ul_style = .single } },
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |seg, i| {
        try std.testing.expectEqualDeep(seg, list.items[i]);
    }
}

test "format.zig: hyperlink" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{
        .bytes = "PRIVMSG #comlink :https://example.org",
    };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    const expected: []const vaxis.Segment = &.{
        .{
            .text = "https://example.org",
            .style = .{ .fg = .{ .index = 4 } },
            .link = .{ .uri = "https://example.org" },
        },
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |seg, i| {
        try std.testing.expectEqualDeep(seg, list.items[i]);
    }
}

test "format.zig: more than hyperlink" {
    const user: irc.User = .{ .nick = "rockorager" };
    const msg: irc.Message = .{
        .bytes = "PRIVMSG #comlink :look https://example.org here",
    };

    var list = std.ArrayList(vaxis.Segment).init(std.testing.allocator);
    defer list.deinit();
    try message(&list, &user, msg);
    const expected: []const vaxis.Segment = &.{
        .{ .text = "look " },
        .{
            .text = "https://example.org",
            .style = .{ .fg = .{ .index = 4 } },
            .link = .{ .uri = "https://example.org" },
        },
        .{ .text = " here" },
    };
    try std.testing.expectEqual(expected.len, list.items.len);
    for (expected, 0..) |seg, i| {
        try std.testing.expectEqualDeep(seg, list.items[i]);
    }
}
