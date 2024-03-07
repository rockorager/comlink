const std = @import("std");
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
    try self.connect();
    // We should be able to read 512 + 8191 = 8703 bytes. Round up to
    // nearest power of 2
    var buf: [10_000]u8 = undefined;

    errdefer |err| {
        log.err("client: {s} error: {}", .{ self.config.network_id.?, err });
    }

    while (true) {
        const n = try self.client.read(self.stream, &buf);
        if (n == 0) break;
        var iter = std.mem.splitSequence(u8, buf[0..n], "\r\n");
        while (iter.next()) |line| {
            if (line.len == 0) continue;
            log.debug("[server] {s}", .{line});
            const duped_line = try self.alloc.dupe(u8, line);
            const msg = Message.init(duped_line, self) catch |err| {
                log.err("[server] invalid message {}", .{err});
                self.alloc.free(duped_line);
                continue;
            };
            self.app.vx.postEvent(.{ .message = msg });
        }
    }
}

pub fn write(self: *Client, buf: []const u8) !void {
    log.debug("[client] {s}", .{buf[0 .. buf.len - 2]});
    try self.client.writeAll(self.stream, buf);
}

pub fn connect(self: *Client) !void {
    self.stream = try std.net.tcpConnectToHost(self.alloc, "chat.sr.ht", 6697);
    self.client = try tls.Client.init(self.stream, self.app.bundle, "chat.sr.ht");

    var buf: [4096]u8 = undefined;

    try self.app.queueWrite(self, "CAP LS 302\r\n");

    const required_caps = [_][]const u8{
        "server-time",
        "message-tags",
        "extended-monitor",
        "away-notify",
        "draft/chathistory",
        "soju.im/bouncer-networks",
        "soju.im/bouncer-networks-notify",
        "sasl",
    };

    const caps = try std.mem.join(self.alloc, " ", &required_caps);
    defer self.alloc.free(caps);

    for (required_caps) |cap| {
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
