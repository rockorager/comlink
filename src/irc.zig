const std = @import("std");
const assert = std.debug.assert;

const log = std.log.scoped(.irc);

pub const Command = enum {
    RPL_WELCOME,
    RPL_YOURHOST,
    RPL_CREATED,
    RPL_MYINFO,
    RPL_ISUPPORT,

    RPL_NAMREPLY,

    RPL_LOGGEDIN,
    RPL_SASLSUCCESS,

    // Named commands
    CAP,
    AUTHENTICATE,
    BOUNCER,

    unknown,

    const map = std.ComptimeStringMap(Command, .{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "353", .RPL_NAMREPLY },
        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "CAP", .CAP },
        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "BOUNCER", .BOUNCER },
    });

    pub fn parse(cmd: []const u8) Command {
        return map.get(cmd) orelse .unknown;
    }
};

pub const Channel = struct {
    name: []const u8,
    members: std.ArrayList(*User),

    pub fn deinit(self: *const Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
    }

    pub fn compare(_: void, lhs: Channel, rhs: Channel) bool {
        return std.mem.order(u8, lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }
};

pub const User = struct {
    nick: []const u8,
    away: bool = false,

    pub fn deinit(self: *const User, alloc: std.mem.Allocator) void {
        alloc.free(self.nick);
    }

    pub fn compare(_: void, lhs: User, rhs: User) bool {
        return std.mem.order(u8, lhs.nick, rhs.nick).compare(std.math.CompareOperator.lt);
    }
};
