const std = @import("std");
const app = @import("app.zig");
const completer = @import("completer.zig");
const vaxis = @import("vaxis");
pub const irc = @import("irc.zig");
pub const lua = @import("lua.zig");

pub const App = app.App;
pub const Completer = completer.Completer;
pub const EventLoop = vaxis.Loop(Event);
pub const WriteQueue = vaxis.Queue(WriteEvent, 64);

pub const Bind = struct {
    key: vaxis.Key,
    command: Command,
};

pub const Command = enum {
    /// a raw irc command. Sent verbatim
    quote,
    join,
    me,
    msg,
    @"next-channel",
    @"prev-channel",
    quit,
    who,
    names,
    part,
    close,
    redraw,

    /// if we should append a space when completing
    pub fn appendSpace(self: Command) bool {
        return switch (self) {
            .quote,
            .join,
            .me,
            .msg,
            .part,
            .close,
            => true,
            else => false,
        };
    }
};

/// Any event our application will handle
pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_out,
    message: irc.Message,
    connect: irc.Client.Config,
    redraw,
    paste_start,
    paste_end,
};

/// An event our write thread will handle
pub const WriteEvent = union(enum) {
    write: struct {
        client: *irc.Client,
        msg: []const u8,
        allocator: std.mem.Allocator,
    },
    join,
};
