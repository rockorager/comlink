const std = @import("std");
const assert = std.debug.assert;

const vaxis = @import("vaxis");
const Message = @import("Message.zig");

const log = std.log.scoped(.irc);

pub const Command = enum {
    RPL_WELCOME, // 001
    RPL_YOURHOST, // 002
    RPL_CREATED, // 003
    RPL_MYINFO, // 004
    RPL_ISUPPORT, // 005

    RPL_TOPIC, // 332
    RPL_WHOREPLY, // 352
    RPL_NAMREPLY, // 353
    RPL_ENDOFNAMES, // 366

    RPL_LOGGEDIN, // 900
    RPL_SASLSUCCESS, // 903

    // Named commands
    AUTHENTICATE,
    AWAY,
    BOUNCER,
    CAP,
    MARKREAD,
    PRIVMSG,

    unknown,

    const map = std.ComptimeStringMap(Command, .{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "332", .RPL_TOPIC },
        .{ "352", .RPL_WHOREPLY },
        .{ "353", .RPL_NAMREPLY },
        .{ "366", .RPL_ENDOFNAMES },

        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "AWAY", .AWAY },
        .{ "BOUNCER", .BOUNCER },
        .{ "CAP", .CAP },
        .{ "MARKREAD", .MARKREAD },
        .{ "PRIVMSG", .PRIVMSG },
    });

    pub fn parse(cmd: []const u8) Command {
        return map.get(cmd) orelse .unknown;
    }
};

pub const Channel = struct {
    name: []const u8,
    topic: ?[]const u8 = null,
    members: std.ArrayList(*User),
    // inited is true after we receive 366 ENDOFNAMES
    inited: bool = false,

    messages: std.ArrayList(Message),
    history_requested: bool = false,
    last_read: i64 = 0,
    has_unread: bool = false,

    pub fn deinit(self: *const Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
        if (self.topic) |topic| {
            alloc.free(topic);
        }
        for (self.messages.items) |msg| {
            msg.deinit(alloc);
        }
        self.messages.deinit();
    }

    pub fn compare(_: void, lhs: Channel, rhs: Channel) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }

    pub fn sortMembers(self: *Channel) !void {
        std.sort.insertion(*User, self.members.items, {}, User.compare);
    }
};

pub const User = struct {
    nick: []const u8,
    away: bool = false,
    color: vaxis.Color = .default,

    pub fn deinit(self: *const User, alloc: std.mem.Allocator) void {
        alloc.free(self.nick);
    }

    pub fn compare(_: void, lhs: *User, rhs: *User) bool {
        return std.ascii.orderIgnoreCase(lhs.nick, rhs.nick).compare(std.math.CompareOperator.lt);
    }
};
