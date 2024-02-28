const std = @import("std");

const log = std.log.scoped(.irc);

pub const Command = enum {
    RPL_WELCOME,
    RPL_YOURHOST,
    RPL_CREATED,
    RPL_MYINFO,
    RPL_ISUPPORT,

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
