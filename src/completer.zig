const std = @import("std");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");

const irc = comlink.irc;
const Command = comlink.Command;

pub const Completer = struct {
    word: []const u8,
    start_idx: usize,
    options: std.ArrayList([]const u8),
    selected_idx: ?usize,
    widest: ?usize,
    buf: [irc.maximum_message_size]u8 = undefined,
    cmd: bool = false, // true when we are completing a command

    pub fn init(alloc: std.mem.Allocator, line: []const u8) !Completer {
        const start_idx = if (std.mem.lastIndexOfScalar(u8, line, ' ')) |idx| idx + 1 else 0;
        const last_word = line[start_idx..];
        var completer: Completer = .{
            .options = std.ArrayList([]const u8).init(alloc),
            .start_idx = start_idx,
            .word = last_word,
            .selected_idx = null,
            .widest = null,
        };
        @memcpy(completer.buf[0..line.len], line);
        if (last_word.len > 0 and last_word[0] == '/') {
            completer.cmd = true;
            try completer.findCommandMatches();
        }
        return completer;
    }

    pub fn deinit(self: *Completer) void {
        self.options.deinit();
    }

    /// cycles to the next option, returns the replacement text. Note that we
    /// start from the bottom, so a selected_idx = 0 means we are on _the last_
    /// item
    pub fn next(self: *Completer) []const u8 {
        if (self.options.items.len == 0) return "";
        {
            const last_idx = self.options.items.len - 1;
            if (self.selected_idx == null or self.selected_idx.? == last_idx)
                self.selected_idx = 0
            else
                self.selected_idx.? +|= 1;
        }
        return self.replacementText();
    }

    pub fn prev(self: *Completer) []const u8 {
        if (self.options.items.len == 0) return "";
        {
            const last_idx = self.options.items.len - 1;
            if (self.selected_idx == null or self.selected_idx.? == 0)
                self.selected_idx = last_idx
            else
                self.selected_idx.? -|= 1;
        }
        return self.replacementText();
    }

    pub fn replacementText(self: *Completer) []const u8 {
        if (self.selected_idx == null or self.options.items.len == 0) return "";
        const replacement = self.options.items[self.options.items.len - 1 - self.selected_idx.?];
        if (self.cmd) {
            self.buf[0] = '/';
            @memcpy(self.buf[1 .. 1 + replacement.len], replacement);
            const append_space = if (Command.fromString(replacement)) |cmd|
                cmd.appendSpace()
            else
                true;
            if (append_space) self.buf[1 + replacement.len] = ' ';
            return self.buf[0 .. 1 + replacement.len + @as(u1, if (append_space) 1 else 0)];
        }
        const start = self.start_idx;
        @memcpy(self.buf[start .. start + replacement.len], replacement);
        if (self.start_idx == 0) {
            @memcpy(self.buf[start + replacement.len .. start + replacement.len + 2], ": ");
            return self.buf[0 .. start + replacement.len + 2];
        } else {
            @memcpy(self.buf[start + replacement.len .. start + replacement.len + 1], " ");
            return self.buf[0 .. start + replacement.len + 1];
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
        self.options = try std.ArrayList([]const u8).initCapacity(alloc, members.items.len);
        for (members.items) |member| {
            try self.options.append(member.user.nick);
        }
    }

    pub fn findCommandMatches(self: *Completer) !void {
        if (self.options.items.len > 0) return;
        self.cmd = true;
        const commands = std.meta.fieldNames(Command);
        for (commands) |cmd| {
            if (std.mem.eql(u8, cmd, "lua_function")) continue;
            if (std.ascii.startsWithIgnoreCase(cmd, self.word[1..])) {
                try self.options.append(cmd);
            }
        }
        var iter = Command.user_commands.keyIterator();
        while (iter.next()) |cmd| {
            if (std.ascii.startsWithIgnoreCase(cmd.*, self.word[1..])) {
                try self.options.append(cmd.*);
            }
        }
    }

    pub fn widestMatch(self: *Completer, win: vaxis.Window) usize {
        if (self.widest) |w| return w;
        var widest: usize = 0;
        for (self.options.items) |opt| {
            const width = win.gwidth(opt);
            if (width > widest) widest = width;
        }
        self.widest = widest;
        return widest;
    }

    pub fn numMatches(self: *Completer) usize {
        return self.options.items.len;
    }
};
