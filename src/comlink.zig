const std = @import("std");
const app = @import("app.zig");
const completer = @import("completer.zig");
const vaxis = @import("vaxis");
pub const irc = @import("irc.zig");
pub const lua = @import("lua.zig");

pub const App = app.App;
pub const Completer = completer.Completer;
pub const EventLoop = vaxis.Loop(Event);
pub const WriteQueue = vaxis.Queue(WriteEvent, 256);

pub const Bind = struct {
    key: vaxis.Key,
    command: Command,
};

pub const Command = union(enum) {
    /// a raw irc command. Sent verbatim
    quote,
    join,
    me,
    msg,
    query,
    @"next-channel",
    @"prev-channel",
    quit,
    who,
    names,
    part,
    close,
    redraw,
    version,
    lua_function: i32,

    pub var user_commands: std.StringHashMap(i32) = undefined;

    /// only contains void commands
    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "quote", .quote },
        .{ "join", .join },
        .{ "me", .me },
        .{ "msg", .msg },
        .{ "query", .query },
        .{ "next-channel", .@"next-channel" },
        .{ "prev-channel", .@"prev-channel" },
        .{ "quit", .quit },
        .{ "who", .who },
        .{ "names", .names },
        .{ "part", .part },
        .{ "close", .close },
        .{ "redraw", .redraw },
        .{ "version", .version },
    });

    pub fn fromString(str: []const u8) ?Command {
        return map.get(str);
    }

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
    irc: IrcEvent,
    connect: irc.Client.Config,
    redraw,
    paste_start,
    paste_end,
};

pub const IrcEvent = struct {
    client: *irc.Client,
    msg: irc.Slice,
};

/// An event our write thread will handle
pub const WriteEvent = union(enum) {
    write: struct {
        client: *irc.Client,
        msg: []const u8,
    },
    join,
};
