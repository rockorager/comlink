const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const tls = std.crypto.tls;

const vaxis = @import("vaxis");
const zeit = @import("zeit");

const App = @import("App.zig");
const zircon = @import("main.zig");

const log = std.log.scoped(.irc);

pub const maximum_message_size = 512;

pub const Command = enum {
    RPL_WELCOME, // 001
    RPL_YOURHOST, // 002
    RPL_CREATED, // 003
    RPL_MYINFO, // 004
    RPL_ISUPPORT, // 005

    RPL_ENDOFWHO, // 315
    RPL_TOPIC, // 332
    RPL_WHOREPLY, // 352
    RPL_NAMREPLY, // 353
    RPL_ENDOFNAMES, // 366

    RPL_LOGGEDIN, // 900
    RPL_SASLSUCCESS, // 903

    // Named commands
    AUTHENTICATE,
    AWAY,
    BATCH,
    BOUNCER,
    CAP,
    CHATHISTORY,
    JOIN,
    MARKREAD,
    NOTICE,
    PART,
    PRIVMSG,

    unknown,

    const map = std.ComptimeStringMap(Command, .{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "315", .RPL_ENDOFWHO },
        .{ "332", .RPL_TOPIC },
        .{ "352", .RPL_WHOREPLY },
        .{ "353", .RPL_NAMREPLY },
        .{ "366", .RPL_ENDOFNAMES },

        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "AWAY", .AWAY },
        .{ "BATCH", .BATCH },
        .{ "BOUNCER", .BOUNCER },
        .{ "CAP", .CAP },
        .{ "CHATHISTORY", .CHATHISTORY },
        .{ "JOIN", .JOIN },
        .{ "MARKREAD", .MARKREAD },
        .{ "NOTICE", .NOTICE },
        .{ "PART", .PART },
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
    state: struct {
        who: struct {
            requested: bool = false,
            end: bool = false,
        } = .{},
    } = .{},

    messages: std.ArrayList(Message),
    history_requested: bool = false,
    at_oldest: bool = false,
    last_read: i64 = 0,
    has_unread: bool = false,
    batches: std.StringHashMap(bool),

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
        var batches = self.batches;
        var iter = batches.keyIterator();
        while (iter.next()) |key| {
            alloc.free(key.*);
        }
        batches.deinit();
    }

    pub fn compare(_: void, lhs: Channel, rhs: Channel) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }

    pub fn sortMembers(self: *Channel) void {
        std.sort.insertion(*User, self.members.items, {}, User.compare);
    }

    pub fn addMember(self: *Channel, user: *User) !void {
        for (self.members.items) |member| {
            if (user == member) return;
        }
        try self.members.append(user);
        self.sortMembers();
    }

    pub fn removeMember(self: *Channel, user: *User) void {
        for (self.members.items, 0..) |member, i| {
            if (user == member) {
                _ = self.members.orderedRemove(i);
                return;
            }
        }
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

/// an irc message
pub const Message = struct {
    client: *Client,
    src: []const u8,
    tags: ?[]const u8,
    source: ?[]const u8,
    command: Command,
    params: ?[]const u8,
    time: ?zeit.Time = null,
    time_buf: ?[]const u8 = null,

    pub fn compareTime(_: void, lhs: Message, rhs: Message) bool {
        const lhs_t = lhs.time orelse return false;
        const rhs_t = rhs.time orelse return false;

        const rhs_instant = rhs_t.instant();
        const lhs_instant = lhs_t.instant();

        return lhs_instant.timestamp < rhs_instant.timestamp;
    }

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

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const TagIterator = struct {
        tags: ?[]const u8,
        index: usize = 0,

        // tags are a list of key=value pairs delimited by semicolons.
        // key[=value] [; key[=value]]
        pub fn next(self: *TagIterator) ?Tag {
            const tags = self.tags orelse return null;
            if (self.index >= tags.len) return null;

            // find next delimiter
            const end = std.mem.indexOfScalarPos(u8, tags, self.index, ';') orelse tags.len;
            var kv_delim = std.mem.indexOfScalarPos(u8, tags, self.index, '=') orelse end;
            // it's possible to have tags like this:
            //     @bot;account=botaccount;+typing=active
            // where the first tag doesn't have a value. Guard against the
            // kv_delim being past the end position
            if (kv_delim > end) kv_delim = end;

            defer self.index = end + 1;

            return .{
                .key = tags[self.index..kv_delim],
                .value = if (end == kv_delim) "" else tags[kv_delim + 1 .. end],
            };
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

        const instant: ?zeit.Time = blk: {
            if (tags == null) break :blk null;
            var tag_iter = TagIterator{ .tags = tags };
            while (tag_iter.next()) |tag| {
                if (!std.mem.eql(u8, tag.key, "time")) continue;
                const instant = try zeit.instant(.{
                    .source = .{ .iso8601 = tag.value },
                    .timezone = &zircon.local,
                });

                break :blk instant.time();
            } else break :blk null;
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
            .time = instant,
        };
    }

    pub fn deinit(msg: Message, alloc: std.mem.Allocator) void {
        alloc.free(msg.src);
        if (msg.time_buf) |buf| alloc.free(buf);
    }

    pub fn paramIterator(msg: Message) ParamIterator {
        return .{ .params = msg.params };
    }

    pub fn tagIterator(msg: Message) TagIterator {
        return .{ .tags = msg.tags };
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
};

pub const Client = struct {
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        password: []const u8,
        real_name: []const u8,
        server: []const u8,
        network_id: ?[]const u8 = null,
        name: ?[]const u8 = null,
    };

    alloc: std.mem.Allocator,
    app: *App,
    client: tls.Client,
    stream: std.net.Stream,
    config: Config,

    channels: std.ArrayList(Channel),
    users: std.StringHashMap(*User),

    should_close: bool = false,
    status: enum {
        connected,
        disconnected,
    } = .disconnected,

    pub fn init(alloc: std.mem.Allocator, app: *App, cfg: Config) !Client {
        return .{
            .alloc = alloc,
            .app = app,
            .client = undefined,
            .stream = undefined,
            .config = cfg,
            .channels = std.ArrayList(Channel).init(alloc),
            .users = std.StringHashMap(*User).init(alloc),
        };
    }

    pub fn deinit(self: *Client) void {
        self.should_close = true;
        _ = self.client.writeEnd(self.stream, "", true) catch |err| {
            log.err("couldn't close tls conn: {}", .{err});
        };
        self.stream.close();
        // id gets allocated in the main thread. We need to deallocate it here if
        // we have one
        if (self.config.network_id) |id| self.alloc.free(id);
        if (self.config.name) |name| self.alloc.free(name);

        for (self.channels.items) |channel| {
            channel.deinit(self.alloc);
        }
        self.channels.deinit();

        var user_iter = self.users.valueIterator();
        while (user_iter.next()) |user| {
            user.*.deinit(self.alloc);
            self.alloc.destroy(user.*);
        }
        self.users.deinit();
    }

    pub fn readLoop(self: *Client) !void {
        var delay: u64 = 1 * std.time.ns_per_s;

        while (!self.should_close) {
            self.status = .disconnected;
            log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
            self.connect() catch {
                self.status = .disconnected;
                log.debug("disconnected", .{});
                log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
                std.time.sleep(delay);
                delay = delay * 2;
                if (delay > std.time.ns_per_min) delay = std.time.ns_per_min;
            };
            log.debug("connected", .{});
            self.status = .connected;
            delay = 1 * std.time.ns_per_s;

            var buf: [16_384]u8 = undefined;

            errdefer |err| {
                log.err("client: {s} error: {}", .{ self.config.network_id.?, err });
            }

            const timeout = std.mem.toBytes(std.posix.timeval{
                .tv_sec = 5,
                .tv_usec = 0,
            });

            const keep_alive: i64 = 10 * std.time.ms_per_s;
            // max round trip time equal to our timeout
            const max_rt: i64 = 5 * std.time.ms_per_s;
            var last_msg: i64 = std.time.milliTimestamp();
            var start: usize = 0;

            while (true) {
                const n = self.client.read(self.stream, buf[start..]) catch |err| {
                    if (err != error.WouldBlock) break;
                    const now = std.time.milliTimestamp();
                    if (now - last_msg > keep_alive + max_rt) {
                        // reconnect??
                        self.status = .disconnected;
                        self.stream.close();
                        self.app.vx.postEvent(.redraw);
                        break;
                    }
                    if (now - last_msg > keep_alive) {
                        // send a ping
                        try self.app.queueWrite(self, "PING zirc\r\n");
                        continue;
                    }
                    continue;
                };
                if (n == 0) continue;
                last_msg = std.time.milliTimestamp();
                var i: usize = 0;
                while (std.mem.indexOfPos(u8, buf[0 .. n + start], i, "\r\n")) |idx| {
                    defer i = idx + 2;
                    const line = try self.alloc.dupe(u8, buf[i..idx]);
                    assert(std.mem.eql(u8, buf[idx .. idx + 2], "\r\n"));
                    log.debug("[<-{s}] {s}", .{ self.config.name orelse self.config.server, line });
                    var msg = Message.init(line, self) catch |err| {
                        log.err("[{s}] invalid message {}", .{ self.config.name orelse self.config.server, err });
                        self.alloc.free(line);
                        continue;
                    };
                    if (msg.time) |time| {
                        msg.time_buf = try std.fmt.allocPrint(
                            self.alloc,
                            "{d:0>2}:{d:0>2}",
                            .{ time.hour, time.minute },
                        );
                    }
                    self.app.vx.postEvent(.{ .message = msg });
                }
                if (i != n) {
                    // we had a part of a line read. Copy it to the beginning of the
                    // buffer
                    std.mem.copyForwards(u8, buf[0 .. (n + start) - i], buf[i..(n + start)]);
                    start = (n + start) - i;
                } else start = 0;
                try std.posix.setsockopt(
                    self.stream.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVTIMEO,
                    &timeout,
                );
            }
        }
    }

    pub fn write(self: *Client, buf: []const u8) !void {
        log.debug("[->{s}] {s}", .{ self.config.name orelse self.config.server, buf[0 .. buf.len - 2] });
        try self.client.writeAll(self.stream, buf);
    }

    pub fn connect(self: *Client) !void {
        self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, 6697);
        self.client = try tls.Client.init(self.stream, self.app.bundle, self.config.server);

        var buf: [4096]u8 = undefined;

        try self.app.queueWrite(self, "CAP LS 302\r\n");

        const caps = [_][]const u8{
            "away-notify",
            "batch",
            "echo-message",
            "message-tags",
            "sasl",
            "server-time",

            "draft/chathistory",
            "draft/no-implicit-names",
            "draft/read-marker",

            "soju.im/bouncer-networks",
            "soju.im/bouncer-networks-notify",
        };

        for (caps) |cap| {
            const cap_req = try std.fmt.bufPrint(
                &buf,
                "CAP REQ :{s}\r\n",
                .{cap},
            );
            try self.app.queueWrite(self, cap_req);
        }

        const nick = try std.fmt.bufPrint(
            &buf,
            "NICK {s}\r\n",
            .{self.config.nick},
        );
        try self.app.queueWrite(self, nick);

        const user = try std.fmt.bufPrint(
            &buf,
            "USER {s} 0 * {s}\r\n",
            .{ self.config.user, self.config.real_name },
        );
        try self.app.queueWrite(self, user);
    }

    pub fn getOrCreateChannel(self: *Client, name: []const u8) !*Channel {
        for (self.channels.items) |*channel| {
            if (std.mem.eql(u8, name, channel.name)) {
                return channel;
            }
        }
        const channel: Channel = .{
            .name = try self.alloc.dupe(u8, name),
            .members = std.ArrayList(*User).init(self.alloc),
            .messages = std.ArrayList(Message).init(self.alloc),
            .batches = std.StringHashMap(bool).init(self.alloc),
        };
        try self.channels.append(channel);

        std.sort.insertion(Channel, self.channels.items, {}, Channel.compare);
        return self.getOrCreateChannel(name);
    }

    var color_indices = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

    pub fn getOrCreateUser(self: *Client, nick: []const u8) !*User {
        return self.users.get(nick) orelse {
            const color_u32 = std.hash.Fnv1a_32.hash(nick);
            const index = color_u32 % color_indices.len;
            const color_index = color_indices[index];

            const color: vaxis.Color = .{
                .index = color_index,
            };
            const user = try self.alloc.create(User);
            user.* = .{
                .nick = try self.alloc.dupe(u8, nick),
                .color = color,
            };
            try self.users.put(user.nick, user);
            return user;
        };
    }
};

pub fn toVaxisColor(irc: u8) vaxis.Color {
    return switch (irc) {
        0 => .default, // white
        1 => .{ .index = 0 }, // black
        2 => .{ .index = 3 }, // blue
        3 => .{ .index = 2 }, // green
        4 => .{ .index = 1 }, // red
        5 => .{ .index = 3 }, // brown
        6 => .{ .index = 5 }, // magenta
        7 => .{ .index = 11 }, // orange
        8 => .{ .index = 11 }, // yellow
        9 => .{ .index = 10 }, // light green
        10 => .{ .index = 6 }, // cyan
        11 => .{ .index = 14 }, // light cyan
        12 => .{ .index = 12 }, // light blue
        13 => .{ .index = 13 }, // pink
        14 => .{ .index = 8 }, // grey
        15 => .{ .index = 7 }, // light grey

        // 16 to 98 are specifically defined
        16 => .{ .index = 52 },
        17 => .{ .index = 94 },
        18 => .{ .index = 100 },
        19 => .{ .index = 58 },
        20 => .{ .index = 22 },
        21 => .{ .index = 29 },
        22 => .{ .index = 23 },
        23 => .{ .index = 24 },
        24 => .{ .index = 17 },
        25 => .{ .index = 54 },
        26 => .{ .index = 53 },
        27 => .{ .index = 89 },
        28 => .{ .index = 88 },
        29 => .{ .index = 130 },
        30 => .{ .index = 142 },
        31 => .{ .index = 64 },
        32 => .{ .index = 28 },
        33 => .{ .index = 35 },
        34 => .{ .index = 30 },
        35 => .{ .index = 25 },
        36 => .{ .index = 18 },
        37 => .{ .index = 91 },
        38 => .{ .index = 90 },
        39 => .{ .index = 125 },
        // TODO: finish these out https://modern.ircdocs.horse/formatting#color

        99 => .default,

        else => .{ .index = irc },
    };
}
