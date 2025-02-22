const std = @import("std");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const emoji = @import("emoji.zig");

const irc = comlink.irc;
const vxfw = vaxis.vxfw;
const Command = comlink.Command;

const Kind = enum {
    command,
    emoji,
    nick,
};

pub const Completer = struct {
    const style: vaxis.Style = .{ .bg = .{ .index = 8 } };
    const selected: vaxis.Style = .{ .bg = .{ .index = 8 }, .reverse = true };

    word: []const u8,
    start_idx: usize,
    options: std.ArrayList(vxfw.Text),
    widest: ?usize,
    buf: [irc.maximum_message_size]u8 = undefined,
    kind: Kind = .nick,
    list_view: vxfw.ListView,
    selected: bool,

    pub fn init(gpa: std.mem.Allocator) Completer {
        return .{
            .options = std.ArrayList(vxfw.Text).init(gpa),
            .start_idx = 0,
            .word = "",
            .widest = null,
            .list_view = undefined,
            .selected = false,
        };
    }

    fn getWidget(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        const self: *Completer = @constCast(@ptrCast(@alignCast(ptr)));
        if (idx < self.options.items.len) {
            const item = &self.options.items[idx];
            if (idx == cursor) {
                item.style = selected;
            } else {
                item.style = style;
            }
            return item.widget();
        }
        return null;
    }

    pub fn reset(self: *Completer, line: []const u8) !void {
        self.list_view = .{
            .children = .{ .builder = .{
                .userdata = self,
                .buildFn = Completer.getWidget,
            } },
            .draw_cursor = false,
        };
        self.start_idx = if (std.mem.lastIndexOfScalar(u8, line, ' ')) |idx| idx + 1 else 0;
        self.word = line[self.start_idx..];
        @memcpy(self.buf[0..line.len], line);
        self.options.clearAndFree();
        self.widest = null;
        self.kind = .nick;
        self.selected = false;

        if (self.word.len > 0 and self.word[0] == '/') {
            self.kind = .command;
            try self.findCommandMatches();
        }
        if (self.word.len > 0 and self.word[0] == ':') {
            self.kind = .emoji;
            try self.findEmojiMatches();
        }
    }

    pub fn deinit(self: *Completer) void {
        self.options.deinit();
    }

    /// cycles to the next option, returns the replacement text. Note that we
    /// start from the bottom, so a selected_idx = 0 means we are on _the last_
    /// item
    pub fn next(self: *Completer, ctx: *vxfw.EventContext) []const u8 {
        if (self.options.items.len == 0) return "";
        if (self.selected) {
            self.list_view.prevItem(ctx);
        }
        self.selected = true;
        return self.replacementText();
    }

    pub fn prev(self: *Completer, ctx: *vxfw.EventContext) []const u8 {
        if (self.options.items.len == 0) return "";
        self.list_view.nextItem(ctx);
        self.selected = true;
        return self.replacementText();
    }

    pub fn replacementText(self: *Completer) []const u8 {
        if (self.options.items.len == 0) return "";
        const replacement_widget = self.options.items[self.list_view.cursor];
        const replacement = replacement_widget.text;
        switch (self.kind) {
            .command => {
                self.buf[0] = '/';
                @memcpy(self.buf[1 .. 1 + replacement.len], replacement);
                const append_space = if (Command.fromString(replacement)) |cmd|
                    cmd.appendSpace()
                else
                    true;
                if (append_space) self.buf[1 + replacement.len] = ' ';
                return self.buf[0 .. 1 + replacement.len + @as(u1, if (append_space) 1 else 0)];
            },
            .emoji => {
                const start = self.start_idx;
                @memcpy(self.buf[start .. start + replacement.len], replacement);
                return self.buf[0 .. start + replacement.len];
            },
            .nick => {
                const start = self.start_idx;
                @memcpy(self.buf[start .. start + replacement.len], replacement);
                if (self.start_idx == 0) {
                    @memcpy(self.buf[start + replacement.len .. start + replacement.len + 2], ": ");
                    return self.buf[0 .. start + replacement.len + 2];
                } else {
                    @memcpy(self.buf[start + replacement.len .. start + replacement.len + 1], " ");
                    return self.buf[0 .. start + replacement.len + 1];
                }
            },
        }
    }

    pub fn findMatches(self: *Completer, chan: *irc.Channel) !void {
        if (self.options.items.len > 0) return;
        const alloc = self.options.allocator;
        var members = std.ArrayList(irc.Channel.Member).init(alloc);
        defer members.deinit();
        for (chan.members.items) |member| {
            if (std.ascii.startsWithIgnoreCase(member.user.nick, self.word)) {
                try members.append(member);
            }
        }
        std.sort.insertion(irc.Channel.Member, members.items, chan, irc.Channel.compareRecentMessages);
        try self.options.ensureTotalCapacity(members.items.len);
        for (members.items) |member| {
            try self.options.append(.{ .text = member.user.nick });
        }
        self.list_view.cursor = @intCast(self.options.items.len -| 1);
        self.list_view.item_count = @intCast(self.options.items.len);
        self.list_view.ensureScroll();
    }

    pub fn findCommandMatches(self: *Completer) !void {
        if (self.options.items.len > 0) return;
        const commands = std.meta.fieldNames(Command);
        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd, "lua_function")) continue;
            if (std.ascii.startsWithIgnoreCase(cmd, self.word[1..])) {
                try self.options.append(.{ .text = cmd });
            }
        }
        var iter = Command.user_commands.keyIterator();
        while (iter.next()) |cmd| {
            if (std.ascii.startsWithIgnoreCase(cmd.*, self.word[1..])) {
                try self.options.append(.{ .text = cmd.* });
            }
        }
        self.list_view.cursor = @intCast(self.options.items.len -| 1);
        self.list_view.item_count = @intCast(self.options.items.len);
        self.list_view.ensureScroll();
    }

    pub fn findEmojiMatches(self: *Completer) !void {
        if (self.options.items.len > 0) return;
        const keys = emoji.map.keys();
        const values = emoji.map.values();

        for (keys, values) |shortcode, glyph| {
            if (std.mem.indexOf(u8, shortcode, self.word[1..])) |_|
                try self.options.append(.{ .text = glyph });
        }
        self.list_view.cursor = @intCast(self.options.items.len -| 1);
        self.list_view.item_count = @intCast(self.options.items.len);
        self.list_view.ensureScroll();
    }

    pub fn widestMatch(self: *Completer, ctx: vxfw.DrawContext) usize {
        if (self.widest) |w| return w;
        var widest: usize = 0;
        for (self.options.items) |opt| {
            const width = ctx.stringWidth(opt.text);
            if (width > widest) widest = width;
        }
        self.widest = widest;
        return widest;
    }

    pub fn numMatches(self: *Completer) usize {
        return self.options.items.len;
    }
};
