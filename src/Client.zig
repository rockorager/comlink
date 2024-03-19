const std = @import("std");
const assert = std.debug.assert;
const tls = std.crypto.tls;
const irc = @import("irc.zig");

const vaxis = @import("vaxis");

const App = @import("App.zig");
const Message = @import("Message.zig");

const log = std.log.scoped(.client);

const Client = @This();

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

channels: std.ArrayList(irc.Channel),
users: std.StringHashMap(*irc.User),

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
        .channels = std.ArrayList(irc.Channel).init(alloc),
        .users = std.StringHashMap(*irc.User).init(alloc),
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

        const timeout = std.mem.toBytes(std.os.timeval{
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
            try std.os.setsockopt(self.stream.handle, std.os.SOL.SOCKET, std.os.SO.RCVTIMEO_NEW, &timeout);
        }
    }
}

pub fn write(self: *Client, buf: []const u8) !void {
    log.debug("[->{s}] {s}", .{ self.config.name orelse self.config.server, buf[0 .. buf.len - 2] });
    try self.client.writeAll(self.stream, buf);
}

pub fn connect(self: *Client) !void {
    self.stream = try std.net.tcpConnectToHost(self.alloc, "chat.sr.ht", 6697);
    self.client = try tls.Client.init(self.stream, self.app.bundle, "chat.sr.ht");

    var buf: [4096]u8 = undefined;

    try self.app.queueWrite(self, "CAP LS 302\r\n");

    const caps = [_][]const u8{
        "echo-message",
        "server-time",
        "message-tags",
        "extended-monitor",
        "away-notify",
        "draft/chathistory",
        "draft/read-marker",
        "soju.im/bouncer-networks",
        "soju.im/bouncer-networks-notify",
        "sasl",
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

pub fn getOrCreateChannel(self: *Client, name: []const u8) !*irc.Channel {
    for (self.channels.items) |*channel| {
        if (std.mem.eql(u8, name, channel.name)) {
            return channel;
        }
    }
    const channel: irc.Channel = .{
        .name = try self.alloc.dupe(u8, name),
        .members = std.ArrayList(*irc.User).init(self.alloc),
        .messages = std.ArrayList(Message).init(self.alloc),
    };
    try self.channels.append(channel);

    std.sort.insertion(irc.Channel, self.channels.items, {}, irc.Channel.compare);
    return self.getOrCreateChannel(name);
}

var color_indices = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

pub fn getOrCreateUser(self: *Client, nick: []const u8) !*irc.User {
    return self.users.get(nick) orelse {
        const color_u32 = std.hash.Fnv1a_32.hash(nick);
        const index = color_u32 % color_indices.len;
        const color_index = color_indices[index];

        const color: vaxis.Color = .{
            .index = color_index,
        };
        const user = try self.alloc.create(irc.User);
        user.* = .{
            .nick = try self.alloc.dupe(u8, nick),
            .color = color,
        };
        try self.users.put(user.nick, user);
        return user;
    };
}
