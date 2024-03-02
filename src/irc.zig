const std = @import("std");
const assert = std.debug.assert;

const vaxis = @import("vaxis");
const ziglyph = vaxis.ziglyph;

const log = std.log.scoped(.irc);

pub const Command = enum {
    RPL_WELCOME, // 001
    RPL_YOURHOST, // 002
    RPL_CREATED, // 003
    RPL_MYINFO, // 004
    RPL_ISUPPORT, // 005

    RPL_TOPIC, // 332
    RPL_NAMREPLY, // 353

    RPL_LOGGEDIN, // 900
    RPL_SASLSUCCESS, // 903

    // Named commands
    AUTHENTICATE,
    AWAY,
    BOUNCER,
    CAP,

    unknown,

    const map = std.ComptimeStringMap(Command, .{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "332", .RPL_TOPIC },
        .{ "353", .RPL_NAMREPLY },
        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "AWAY", .AWAY },
        .{ "BOUNCER", .BOUNCER },
        .{ "CAP", .CAP },
    });

    pub fn parse(cmd: []const u8) Command {
        return map.get(cmd) orelse .unknown;
    }
};

pub const Channel = struct {
    name: []const u8,
    topic: ?[]const u8 = null,
    members: std.ArrayList(*User),

    pub fn deinit(self: *const Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
        if (self.topic) |topic| {
            alloc.free(topic);
        }
    }

    pub fn compare(_: void, lhs: Channel, rhs: Channel) bool {
        return std.mem.order(u8, lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
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
        var lhs_iter: ziglyph.CodePointIterator = .{ .bytes = lhs.nick };
        var rhs_iter: ziglyph.CodePointIterator = .{ .bytes = rhs.nick };
        while (lhs_iter.next()) |lhs_cp| {
            const rhs_cp = rhs_iter.next() orelse return false;
            const lhs_lower = ziglyph.toLower(lhs_cp.code);
            const rhs_lower = ziglyph.toLower(rhs_cp.code);
            if (lhs_lower != rhs_lower) {
                return lhs_lower < rhs_lower;
            }
        }
        return false;
    }
};
