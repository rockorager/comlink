const std = @import("std");
const comlink = @import("comlink.zig");
const tls = @import("tls");
const vaxis = @import("vaxis");
const zeit = @import("zeit");
const bytepool = @import("pool.zig");

const testing = std.testing;

pub const MessagePool = bytepool.BytePool(max_raw_msg_size * 4);
pub const Slice = MessagePool.Slice;

const assert = std.debug.assert;

const log = std.log.scoped(.irc);

/// maximum size message we can write
pub const maximum_message_size = 512;

/// maximum size message we can receive
const max_raw_msg_size = 512 + 8191; // see modernircdocs

pub const Buffer = union(enum) {
    client: *Client,
    channel: *Channel,
};

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
    RPL_WHOSPCRPL, // 354
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

    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "315", .RPL_ENDOFWHO },
        .{ "332", .RPL_TOPIC },
        .{ "352", .RPL_WHOREPLY },
        .{ "353", .RPL_NAMREPLY },
        .{ "354", .RPL_WHOSPCRPL },
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
    client: *Client,
    name: []const u8,
    topic: ?[]const u8 = null,
    members: std.ArrayList(Member),
    in_flight: struct {
        who: bool = false,
        names: bool = false,
    } = .{},

    messages: std.ArrayList(Message),
    history_requested: bool = false,
    who_requested: bool = false,
    at_oldest: bool = false,
    last_read: i64 = 0,
    has_unread: bool = false,
    has_unread_highlight: bool = false,

    pub const Member = struct {
        user: *User,

        /// Highest channel membership prefix (or empty space if no prefix)
        prefix: u8,

        pub fn compare(_: void, lhs: Member, rhs: Member) bool {
            return if (lhs.prefix != ' ' and rhs.prefix == ' ')
                true
            else if (lhs.prefix == ' ' and rhs.prefix != ' ')
                false
            else
                std.ascii.orderIgnoreCase(lhs.user.nick, rhs.user.nick).compare(.lt);
        }
    };

    pub fn deinit(self: *const Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
        if (self.topic) |topic| {
            alloc.free(topic);
        }
        for (self.messages.items) |msg| {
            alloc.free(msg.bytes);
        }
        self.messages.deinit();
    }

    pub fn compare(_: void, lhs: Channel, rhs: Channel) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }

    pub fn compareRecentMessages(self: *Channel, lhs: Member, rhs: Member) bool {
        var l: i64 = 0;
        var r: i64 = 0;
        var iter = std.mem.reverseIterator(self.messages.items);
        while (iter.next()) |msg| {
            if (msg.source()) |source| {
                const bang = std.mem.indexOfScalar(u8, source, '!') orelse source.len;
                const nick = source[0..bang];

                if (l == 0 and msg.time() != null and std.mem.eql(u8, lhs.user.nick, nick)) {
                    l = msg.time().?.unixTimestamp();
                } else if (r == 0 and msg.time() != null and std.mem.eql(u8, rhs.user.nick, nick))
                    r = msg.time().?.unixTimestamp();
            }
            if (l > 0 and r > 0) break;
        }
        return l < r;
    }

    pub fn sortMembers(self: *Channel) void {
        std.sort.insertion(Member, self.members.items, {}, Member.compare);
    }

    pub fn addMember(self: *Channel, user: *User, args: struct {
        prefix: ?u8 = null,
        sort: bool = true,
    }) !void {
        if (args.prefix) |p| {
            log.debug("adding member: nick={s}, prefix={c}", .{ user.nick, p });
        }
        for (self.members.items) |*member| {
            if (user == member.user) {
                // Update the prefix for an existing member if the prefix is
                // known
                if (args.prefix) |p| member.prefix = p;
                return;
            }
        }

        try self.members.append(.{ .user = user, .prefix = args.prefix orelse ' ' });

        if (args.sort) {
            self.sortMembers();
        }
    }

    pub fn removeMember(self: *Channel, user: *User) void {
        for (self.members.items, 0..) |member, i| {
            if (user == member.user) {
                _ = self.members.orderedRemove(i);
                return;
            }
        }
    }

    /// issue a MARKREAD command for this channel. The most recent message in the channel will be used as
    /// the last read time
    pub fn markRead(self: *Channel) !void {
        if (!self.has_unread) return;

        self.has_unread = false;
        self.has_unread_highlight = false;
        const last_msg = self.messages.getLast();
        const time_tag = last_msg.getTag("time") orelse return;
        var write_buf: [128]u8 = undefined;
        const mark_read = try std.fmt.bufPrint(
            &write_buf,
            "MARKREAD {s} timestamp={s}\r\n",
            .{
                self.name,
                time_tag,
            },
        );
        try self.client.queueWrite(mark_read);
    }
};

pub const User = struct {
    nick: []const u8,
    away: bool = false,
    color: vaxis.Color = .default,
    real_name: ?[]const u8 = null,

    pub fn deinit(self: *const User, alloc: std.mem.Allocator) void {
        alloc.free(self.nick);
        if (self.real_name) |realname| alloc.free(realname);
    }
};

/// an irc message
pub const Message = struct {
    bytes: []const u8,

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
        tags: []const u8,
        index: usize = 0,

        // tags are a list of key=value pairs delimited by semicolons.
        // key[=value] [; key[=value]]
        pub fn next(self: *TagIterator) ?Tag {
            if (self.index >= self.tags.len) return null;

            // find next delimiter
            const end = std.mem.indexOfScalarPos(u8, self.tags, self.index, ';') orelse self.tags.len;
            var kv_delim = std.mem.indexOfScalarPos(u8, self.tags, self.index, '=') orelse end;
            // it's possible to have tags like this:
            //     @bot;account=botaccount;+typing=active
            // where the first tag doesn't have a value. Guard against the
            // kv_delim being past the end position
            if (kv_delim > end) kv_delim = end;

            defer self.index = end + 1;

            return .{
                .key = self.tags[self.index..kv_delim],
                .value = if (end == kv_delim) "" else self.tags[kv_delim + 1 .. end],
            };
        }
    };

    pub fn tagIterator(msg: Message) TagIterator {
        const src = msg.bytes;
        if (src[0] != '@') return .{ .tags = "" };

        assert(src.len > 1);
        const n = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse src.len;
        return .{ .tags = src[1..n] };
    }

    pub fn source(msg: Message) ?[]const u8 {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return null;
        }

        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // Start of source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
            return src[i..end];
        }

        return null;
    }

    pub fn command(msg: Message) Command {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        assert(src.len > i);
        // Find next space
        const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
        return Command.parse(src[i..end]);
    }

    pub fn paramIterator(msg: Message) ParamIterator {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            i = std.mem.indexOfScalarPos(u8, src, 0, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past command
        i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };

        assert(src.len > i);
        return .{ .params = src[i + 1 ..] };
    }

    /// Returns the value of the tag 'key', if present
    pub fn getTag(self: Message, key: []const u8) ?[]const u8 {
        var tag_iter = self.tagIterator();
        while (tag_iter.next()) |tag| {
            if (!std.mem.eql(u8, tag.key, key)) continue;
            return tag.value;
        }
        return null;
    }

    pub fn time(self: Message) ?zeit.Instant {
        const val = self.getTag("time") orelse return null;

        // Return null if we can't parse the time
        const instant = zeit.instant(.{
            .source = .{ .iso8601 = val },
            .timezone = &zeit.utc,
        }) catch return null;

        return instant;
    }

    pub fn localTime(self: Message, tz: *const zeit.TimeZone) ?zeit.Instant {
        const utc = self.time() orelse return null;
        return utc.in(tz);
    }

    pub fn compareTime(_: void, lhs: Message, rhs: Message) bool {
        const lhs_time = lhs.time() orelse return false;
        const rhs_time = rhs.time() orelse return false;

        return lhs_time.timestamp < rhs_time.timestamp;
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
        tls: bool = true,
        lua_table: i32,
    };

    pub const Capabilities = struct {
        @"away-notify": bool = false,
        batch: bool = false,
        @"echo-message": bool = false,
        @"message-tags": bool = false,
        sasl: bool = false,
        @"server-time": bool = false,

        @"draft/chathistory": bool = false,
        @"draft/no-implicit-names": bool = false,
        @"draft/read-marker": bool = false,

        @"soju.im/bouncer-networks": bool = false,
        @"soju.im/bouncer-networks-notify": bool = false,
    };

    /// ISupport are features only advertised via ISUPPORT that we care about
    pub const ISupport = struct {
        whox: bool = false,
        prefix: []const u8 = "",
    };

    alloc: std.mem.Allocator,
    app: *comlink.App,
    client: tls.Connection(std.net.Stream),
    stream: std.net.Stream,
    config: Config,

    channels: std.ArrayList(Channel),
    users: std.StringHashMap(*User),

    should_close: bool = false,
    status: enum {
        connected,
        disconnected,
    } = .disconnected,

    caps: Capabilities = .{},
    supports: ISupport = .{},

    batches: std.StringHashMap(*Channel),
    write_queue: *comlink.WriteQueue,

    thread: ?std.Thread = null,

    pub fn init(alloc: std.mem.Allocator, app: *comlink.App, wq: *comlink.WriteQueue, cfg: Config) !Client {
        return .{
            .alloc = alloc,
            .app = app,
            .client = undefined,
            .stream = undefined,
            .config = cfg,
            .channels = std.ArrayList(Channel).init(alloc),
            .users = std.StringHashMap(*User).init(alloc),
            .batches = std.StringHashMap(*Channel).init(alloc),
            .write_queue = wq,
        };
    }

    pub fn deinit(self: *Client) void {
        self.should_close = true;
        if (self.status == .connected) {
            self.write("PING comlink\r\n") catch |err|
                log.err("couldn't close tls conn: {}", .{err});
            if (self.thread) |thread| {
                thread.detach();
                self.thread = null;
            }
        }
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
        self.alloc.free(self.supports.prefix);
        var batches = self.batches;
        var iter = batches.keyIterator();
        while (iter.next()) |key| {
            self.alloc.free(key.*);
        }
        batches.deinit();
    }

    pub fn ack(self: *Client, cap: []const u8) void {
        const info = @typeInfo(Capabilities);
        assert(info == .Struct);

        inline for (info.Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, cap)) {
                @field(self.caps, field.name) = true;
                return;
            }
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        switch (self.config.tls) {
            true => return self.client.read(buf),
            false => return self.stream.read(buf),
        }
    }

    pub fn readLoop(self: *Client, loop: *comlink.EventLoop) !void {
        var delay: u64 = 1 * std.time.ns_per_s;

        while (!self.should_close) {
            self.status = .disconnected;
            log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
            self.connect() catch |err| {
                log.err("connection error: {}", .{err});
                self.status = .disconnected;
                log.debug("disconnected", .{});
                log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
                std.time.sleep(delay);
                delay = delay * 2;
                if (delay > std.time.ns_per_min) delay = std.time.ns_per_min;
                continue;
            };
            log.debug("connected", .{});
            self.status = .connected;
            delay = 1 * std.time.ns_per_s;

            var buf: [16_384]u8 = undefined;

            // 4x max size. We will almost always be *way* under our maximum size, so we will have a
            // lot more potential messages than just 4
            var pool: MessagePool = .{};
            pool.init();

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
                const n = self.read(buf[start..]) catch |err| {
                    if (err != error.WouldBlock) break;
                    const now = std.time.milliTimestamp();
                    if (now - last_msg > keep_alive + max_rt) {
                        // reconnect??
                        self.status = .disconnected;
                        loop.postEvent(.redraw);
                        break;
                    }
                    if (now - last_msg > keep_alive) {
                        // send a ping
                        try self.queueWrite("PING comlink\r\n");
                        continue;
                    }
                    continue;
                };
                if (self.should_close) return;
                log.debug("read {d}", .{n});
                if (n == 0) {
                    self.status = .disconnected;
                    loop.postEvent(.redraw);
                    break;
                }
                last_msg = std.time.milliTimestamp();
                var i: usize = 0;
                while (std.mem.indexOfPos(u8, buf[0 .. n + start], i, "\r\n")) |idx| {
                    defer i = idx + 2;
                    const buffer = pool.alloc(idx - i);
                    // const line = try self.alloc.dupe(u8, buf[i..idx]);
                    @memcpy(buffer.slice(), buf[i..idx]);
                    assert(std.mem.eql(u8, buf[idx .. idx + 2], "\r\n"));
                    log.debug("[<-{s}] {s}", .{ self.config.name orelse self.config.server, buffer.slice() });
                    loop.postEvent(.{ .irc = .{ .client = self, .msg = buffer } });
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

    /// push a write request into the queue. The request should include the trailing
    /// '\r\n'. queueWrite will dupe the message and free after processing.
    pub fn queueWrite(self: *Client, msg: []const u8) !void {
        self.write_queue.push(.{ .write = .{
            .client = self,
            .msg = try self.alloc.dupe(u8, msg),
            .allocator = self.alloc,
        } });
    }

    pub fn write(self: *Client, buf: []const u8) !void {
        log.debug("[->{s}] {s}", .{ self.config.name orelse self.config.server, buf[0 .. buf.len - 2] });
        switch (self.config.tls) {
            true => try self.client.writeAll(buf),
            false => try self.stream.writeAll(buf),
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.config.tls) {
            self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, 6697);
            self.client = try tls.client(self.stream, .{
                .host = self.config.server,
                .root_ca = self.app.bundle,
            });
        } else {
            self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, 6667);
        }

        var buf: [4096]u8 = undefined;

        try self.queueWrite("CAP LS 302\r\n");

        const cap_names = std.meta.fieldNames(Capabilities);
        for (cap_names) |cap| {
            const cap_req = try std.fmt.bufPrint(
                &buf,
                "CAP REQ :{s}\r\n",
                .{cap},
            );
            try self.queueWrite(cap_req);
        }

        const nick = try std.fmt.bufPrint(
            &buf,
            "NICK {s}\r\n",
            .{self.config.nick},
        );
        try self.queueWrite(nick);

        const user = try std.fmt.bufPrint(
            &buf,
            "USER {s} 0 * {s}\r\n",
            .{ self.config.user, self.config.real_name },
        );
        try self.queueWrite(user);
    }

    pub fn getOrCreateChannel(self: *Client, name: []const u8) !*Channel {
        for (self.channels.items) |*channel| {
            if (caseFold(name, channel.name)) return channel;
        }
        const channel: Channel = .{
            .name = try self.alloc.dupe(u8, name),
            .members = std.ArrayList(Channel.Member).init(self.alloc),
            .messages = std.ArrayList(Message).init(self.alloc),
            .client = self,
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

    pub fn whox(self: *Client, channel: *Channel) !void {
        channel.who_requested = true;
        if (channel.name.len > 0 and
            channel.name[0] != '#')
        {
            const other = try self.getOrCreateUser(channel.name);
            const me = try self.getOrCreateUser(self.config.nick);
            try channel.addMember(other, .{});
            try channel.addMember(me, .{});
            return;
        }
        // Only use WHO if we have WHOX and away-notify. Without
        // WHOX, we can get rate limited on eg. libera. Without
        // away-notify, our list will become stale
        if (self.supports.whox and
            self.caps.@"away-notify" and
            !channel.in_flight.who)
        {
            var write_buf: [64]u8 = undefined;
            channel.in_flight.who = true;
            const who = try std.fmt.bufPrint(
                &write_buf,
                "WHO {s} %cnfr\r\n",
                .{channel.name},
            );
            try self.queueWrite(who);
        } else {
            var write_buf: [64]u8 = undefined;
            channel.in_flight.names = true;
            const names = try std.fmt.bufPrint(
                &write_buf,
                "NAMES {s}\r\n",
                .{channel.name},
            );
            try self.queueWrite(names);
        }
    }

    /// fetch the history for the provided channel.
    pub fn requestHistory(self: *Client, cmd: ChatHistoryCommand, channel: *Channel) !void {
        if (!self.caps.@"draft/chathistory") return;
        if (channel.history_requested) return;

        channel.history_requested = true;

        var buf: [128]u8 = undefined;
        if (channel.messages.items.len == 0) {
            const hist = try std.fmt.bufPrint(
                &buf,
                "CHATHISTORY LATEST {s} * 50\r\n",
                .{channel.name},
            );
            channel.history_requested = true;
            try self.queueWrite(hist);
            return;
        }

        switch (cmd) {
            .before => {
                assert(channel.messages.items.len > 0);
                const first = channel.messages.items[0];
                const time = first.getTag("time") orelse
                    return error.NoTimeTag;
                const hist = try std.fmt.bufPrint(
                    &buf,
                    "CHATHISTORY BEFORE {s} timestamp={s} 50\r\n",
                    .{ channel.name, time },
                );
                channel.history_requested = true;
                try self.queueWrite(hist);
            },
            .after => {
                assert(channel.messages.items.len > 0);
                const last = channel.messages.getLast();
                const time = last.getTag("time") orelse
                    return error.NoTimeTag;
                const hist = try std.fmt.bufPrint(
                    &buf,
                    // we request 500 because we have no
                    // idea how long we've been offline
                    "CHATHISTORY AFTER {s} timestamp={s} 500\r\n",
                    .{ channel.name, time },
                );
                channel.history_requested = true;
                try self.queueWrite(hist);
            },
        }
    }
};

pub fn toVaxisColor(irc: u8) vaxis.Color {
    return switch (irc) {
        0 => .default, // white
        1 => .{ .index = 0 }, // black
        2 => .{ .index = 4 }, // blue
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

const CaseMapAlgo = enum {
    ascii,
    rfc1459,
    rfc1459_strict,
};

pub fn caseMap(char: u8, algo: CaseMapAlgo) u8 {
    switch (algo) {
        .ascii => {
            switch (char) {
                'A'...'Z' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459 => {
            switch (char) {
                'A'...'^' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459_strict => {
            switch (char) {
                'A'...']' => return char + 0x20,
                else => return char,
            }
        },
    }
}

pub fn caseFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) {
        const diff = std.mem.indexOfDiff(u8, a[i..], b[i..]) orelse return true;
        const a_diff = caseMap(a[diff], .rfc1459);
        const b_diff = caseMap(b[diff], .rfc1459);
        if (a_diff != b_diff) return false;
        i += diff + 1;
    }
    return true;
}

pub const ChatHistoryCommand = enum {
    before,
    after,
};

test "caseFold" {
    try testing.expect(caseFold("a", "A"));
    try testing.expect(caseFold("aBcDeFgH", "abcdefgh"));
}

test "simple message" {
    const msg: Message = .{ .bytes = "JOIN" };
    try testing.expect(msg.command() == .JOIN);
}

test "simple message with extra whitespace" {
    const msg: Message = .{ .bytes = "JOIN      " };
    try testing.expect(msg.command() == .JOIN);
}

test "well formed message with tags, source, params" {
    const msg: Message = .{ .bytes = "@key=value :example.chat JOIN abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
}

test "message with tags, source, params and extra whitespace" {
    const msg: Message = .{ .bytes = "@key=value        :example.chat        JOIN    abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
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
