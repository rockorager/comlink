const std = @import("std");
const vaxis = @import("vaxis");
const zeit = @import("zeit");
const ziglua = @import("ziglua");

const assert = std.debug.assert;
const base64 = std.base64.standard.Encoder;
const mem = std.mem;

const Button = @import("Button.zig");
const irc = @import("irc.zig");
const lua = @import("lua.zig");

// data structures
const Client = irc.Client;
const Lua = @import("ziglua").Lua;
const Message = irc.Message;

const log = std.log.scoped(.app);

const App = @This();

/// Any event our application will handle
pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    focus_out,
    message: Message,
    connect: Client.Config,
    redraw,
    paste_start,
    paste_end,
};

pub const WriteRequest = struct {
    client: *Client,
    msg: []const u8,
};

const ChatHistoryCommand = enum {
    before,
    after,
};

const Buffer = union(enum) {
    client: *Client,
    channel: *irc.Channel,
};

pub const Bind = struct {
    key: vaxis.Key,
    command: Command,
};

/// allocator used for all allocations in the application
alloc: std.mem.Allocator,

/// the Certificate Bundle
bundle: std.crypto.Certificate.Bundle = .{},

/// List of all configured clients
clients: std.ArrayList(*Client),

/// if we have already called deinit
deinited: bool = false,

/// Our lua state
lua: *Lua,

/// the vaxis instance for our application
vx: vaxis.Vaxis,
tty: vaxis.Tty,

loop: ?vaxis.Loop(Event) = null,

/// our queue of writes
write_queue: vaxis.Queue(WriteRequest, 128) = .{},

state: State = .{},

content_segments: std.ArrayList(vaxis.Segment),

completer: ?Completer = null,

should_quit: bool = false,

binds: std.ArrayList(Bind),

paste_buffer: std.ArrayList(u8),

input: vaxis.widgets.TextInput = undefined,

const State = struct {
    mouse: ?vaxis.Mouse = null,
    members: struct {
        scroll_offset: usize = 0,
        width: usize = 16,
        resizing: bool = false,
    } = .{},
    messages: struct {
        scroll_offset: usize = 0,
    } = .{},
    buffers: struct {
        scroll_offset: usize = 0,
        count: usize = 0,
        selected_idx: usize = 0,
        width: usize = 16,
        resizing: bool = false,
    } = .{},
    paste: struct {
        pasting: bool = false,
        has_newline: bool = false,

        fn showDialog(self: @This()) bool {
            return !self.pasting and self.has_newline;
        }
    } = .{},
};

/// initialize vaxis, lua state
pub fn init(alloc: std.mem.Allocator) !App {
    const vx = try vaxis.init(alloc, .{});
    var app: App = .{
        .alloc = alloc,
        .clients = std.ArrayList(*Client).init(alloc),
        .lua = try Lua.init(&alloc),
        .vx = vx,
        .tty = try vaxis.Tty.init(),
        .content_segments = std.ArrayList(vaxis.Segment).init(alloc),
        .binds = try std.ArrayList(Bind).initCapacity(alloc, 16),
        .paste_buffer = std.ArrayList(u8).init(alloc),
        .input = vaxis.widgets.TextInput.init(alloc, &vx.unicode),
    };

    try app.binds.append(.{
        .key = .{
            .codepoint = 'c',
            .mods = .{ .ctrl = true },
        },
        .command = .quit,
    });
    try app.binds.append(.{
        .key = .{
            .codepoint = vaxis.Key.up,
            .mods = .{ .alt = true },
        },
        .command = .@"prev-channel",
    });
    try app.binds.append(.{
        .key = .{
            .codepoint = vaxis.Key.down,
            .mods = .{ .alt = true },
        },
        .command = .@"next-channel",
    });

    // Get our system tls certs
    try app.bundle.rescan(alloc);

    return app;
}

/// close the application. This closes the TUI, disconnects clients, and cleans
/// up all resources
pub fn deinit(self: *App) void {
    if (self.deinited) return;
    self.deinited = true;

    // clean up clients
    {
        for (self.clients.items, 0..) |_, i| {
            var client = self.clients.items[i];
            client.deinit();
            self.alloc.destroy(client);
        }
        self.clients.deinit();
    }

    self.lua.deinit();
    self.bundle.deinit(self.alloc);
    // drain the queue
    if (self.loop) |*loop| {
        while (loop.queue.tryPop()) |event| {
            switch (event) {
                .message => |msg| msg.deinit(self.alloc),
                else => {},
            }
        }
        loop.stop();
    }
    // close vaxis
    {
        self.vx.deinit(self.alloc, self.tty.anyWriter());
    }
    self.tty.deinit();

    self.content_segments.deinit();
    if (self.completer) |*completer| completer.deinit();
    self.binds.deinit();
    self.paste_buffer.deinit();
}

/// push a write request into the queue. The request should include the trailing
/// '\r\n'. queueWrite will dupe the message and free after processing.
pub fn queueWrite(self: *App, client: *Client, msg: []const u8) !void {
    self.write_queue.push(.{
        .client = client,
        .msg = try self.alloc.dupe(u8, msg),
    });
}

/// this loop is run in a separate thread and handles writes to all clients.
/// Message content is deallocated when the write request is completed
fn writeLoop(self: *App) !void {
    log.debug("starting write thread", .{});
    while (true) {
        var req = self.write_queue.pop();
        try req.client.write(req.msg);
        self.alloc.free(req.msg);
    }
}

pub fn run(self: *App) !void {
    // start vaxis
    const writer = self.tty.anyWriter();
    {
        self.loop = .{
            .vaxis = &self.vx,
            .tty = &self.tty,
        };
        try self.loop.?.init();
        try self.loop.?.start();
        try self.vx.enterAltScreen(writer);
        try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
        try self.vx.setMouseMode(writer, true);
        try self.vx.setBracketedPaste(writer, true);
    }

    // start our write thread
    {
        const write_thread = try std.Thread.spawn(.{}, App.writeLoop, .{self});
        write_thread.detach();
    }

    // initialize lua state
    {
        // load standard libraries
        self.lua.openLibs();

        // preload our library
        _ = try self.lua.getGlobal("package"); // [package]
        _ = self.lua.getField(-1, "preload"); // [package, preload]
        self.lua.pushFunction(ziglua.wrap(lua.preloader)); // [package, preload, function]
        self.lua.setField(-2, "comlink"); // [package, preload]
        // empty the stack
        self.lua.pop(2); // []

        // keep a reference to our app in the lua state
        self.lua.pushLightUserdata(self); // [userdata]
        self.lua.setField(lua.registry_index, lua.app_key); // []

        // load config
        const home = std.posix.getenv("HOME") orelse return error.EnvironmentVariableNotFound;
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&buf, "{s}/.config/comlink/init.lua", .{home});
        switch (ziglua.lang) {
            .luajit, .lua51 => self.lua.loadFile(path) catch return error.LuaError,
            else => self.lua.loadFile(path, .binary_text) catch return error.LuaError,
        }
        self.lua.protectedCall(0, ziglua.mult_return, 0) catch return error.LuaError;
    }

    defer self.input.deinit();

    loop: while (!self.should_quit) {
        self.loop.?.pollEvent();
        while (self.loop.?.tryEvent()) |event| {
            switch (event) {
                .redraw => {},
                .key_press => |key| {
                    if (self.state.paste.showDialog()) {
                        if (key.matches(vaxis.Key.escape, .{})) {
                            self.state.paste.has_newline = false;
                            self.paste_buffer.clearAndFree();
                        }
                        break;
                    }
                    if (self.state.paste.pasting) {
                        if (key.matches(vaxis.Key.enter, .{})) {
                            self.state.paste.has_newline = true;
                            try self.paste_buffer.append('\n');
                            continue :loop;
                        }
                        const text = key.text orelse continue :loop;
                        try self.paste_buffer.appendSlice(text);
                        continue :loop;
                    }
                    for (self.binds.items) |bind| {
                        if (key.matches(bind.key.codepoint, bind.key.mods)) {
                            switch (bind.command) {
                                .quit => self.should_quit = true,
                                .@"next-channel" => self.nextChannel(),
                                .@"prev-channel" => self.prevChannel(),
                                else => {},
                            }
                            break;
                        }
                    } else if (key.matches(vaxis.Key.tab, .{})) {
                        // if we already have a completion word, then we are
                        // cycling through the options
                        if (self.completer) |*completer| {
                            const line = completer.next();
                            self.input.clearRetainingCapacity();
                            try self.input.insertSliceAtCursor(line);
                        } else {
                            var completion_buf: [irc.maximum_message_size]u8 = undefined;
                            const content = self.input.sliceToCursor(&completion_buf);
                            self.completer = try Completer.init(self.alloc, content);
                        }
                    } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
                        if (self.completer) |*completer| {
                            const line = completer.prev();
                            self.input.clearRetainingCapacity();
                            try self.input.insertSliceAtCursor(line);
                        }
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (self.input.buf.realLength() == 0) continue;
                        const buffer = self.selectedBuffer() orelse @panic("no buffer");
                        const content = try self.input.toOwnedSlice();
                        defer self.alloc.free(content);
                        if (content[0] == '/')
                            self.handleCommand(buffer, content) catch |err| {
                                log.err("couldn't handle command: {}", .{err});
                            }
                        else {
                            switch (buffer) {
                                .channel => |channel| {
                                    var buf: [1024]u8 = undefined;
                                    const msg = try std.fmt.bufPrint(
                                        &buf,
                                        "PRIVMSG {s} :{s}\r\n",
                                        .{
                                            channel.name,
                                            content,
                                        },
                                    );
                                    try self.queueWrite(channel.client, msg);
                                },
                                .client => log.err("can't send message to client", .{}),
                            }
                        }
                        if (self.completer != null) {
                            self.completer.?.deinit();
                            self.completer = null;
                        }
                    } else {
                        if (self.completer != null and !key.isModifier()) {
                            self.completer.?.deinit();
                            self.completer = null;
                        }
                        log.debug("{}", .{key});
                        try self.input.update(.{ .key_press = key });
                    }
                },
                .paste_start => self.state.paste.pasting = true,
                .paste_end => {
                    self.state.paste.pasting = false;
                    if (self.state.paste.has_newline) {
                        log.warn("NEWLINE", .{});
                    } else {
                        try self.input.insertSliceAtCursor(self.paste_buffer.items);
                        defer self.paste_buffer.clearAndFree();
                    }
                },
                .focus_out => self.state.mouse = null,
                .mouse => |mouse| {
                    self.state.mouse = mouse;
                    log.debug("mouse event: {}", .{mouse});
                },
                .winsize => |ws| try self.vx.resize(self.alloc, writer, ws),
                .connect => |cfg| {
                    const client = try self.alloc.create(Client);
                    client.* = try Client.init(self.alloc, self, cfg);
                    const client_read_thread = try std.Thread.spawn(.{}, Client.readLoop, .{client});
                    client_read_thread.detach();
                    try self.clients.append(client);
                },
                .message => |msg| {
                    var keep_message: bool = false;
                    defer {
                        if (!keep_message) msg.deinit(self.alloc);
                    }
                    switch (msg.command) {
                        .unknown => {},
                        .CAP => {
                            // syntax: <client> <ACK/NACK> :caps
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue; // client
                            const ack_or_nak = iter.next() orelse continue;
                            const caps = iter.next() orelse continue;
                            var cap_iter = mem.splitScalar(u8, caps, ' ');
                            while (cap_iter.next()) |cap| {
                                if (mem.eql(u8, ack_or_nak, "ACK")) {
                                    msg.client.ack(cap);
                                    if (mem.eql(u8, cap, "sasl"))
                                        try self.queueWrite(msg.client, "AUTHENTICATE PLAIN\r\n");
                                } else if (mem.eql(u8, ack_or_nak, "NAK")) {
                                    log.debug("CAP not supported {s}", .{cap});
                                }
                            }
                        },
                        .AUTHENTICATE => {
                            var iter = msg.paramIterator();
                            while (iter.next()) |param| {
                                // A '+' is the continuuation to send our
                                // AUTHENTICATE info
                                if (!mem.eql(u8, param, "+")) continue;
                                var buf: [4096]u8 = undefined;
                                const config = msg.client.config;
                                const sasl = try std.fmt.bufPrint(
                                    &buf,
                                    "{s}\x00{s}\x00{s}",
                                    .{ config.user, config.nick, config.password },
                                );

                                // Create a buffer big enough for the base64 encoded string
                                const b64_buf = try self.alloc.alloc(u8, base64.calcSize(sasl.len));
                                defer self.alloc.free(b64_buf);
                                const encoded = base64.encode(b64_buf, sasl);
                                // Make our message
                                const auth = try std.fmt.bufPrint(
                                    &buf,
                                    "AUTHENTICATE {s}\r\n",
                                    .{encoded},
                                );
                                try self.queueWrite(msg.client, auth);
                                if (config.network_id) |id| {
                                    const bind = try std.fmt.bufPrint(
                                        &buf,
                                        "BOUNCER BIND {s}\r\n",
                                        .{id},
                                    );
                                    try self.queueWrite(msg.client, bind);
                                }
                                try self.queueWrite(msg.client, "CAP END\r\n");
                            }
                        },
                        .RPL_WELCOME => {
                            const now = try zeit.instant(.{});
                            var now_buf: [30]u8 = undefined;
                            const now_fmt = try now.time().bufPrint(&now_buf, .rfc3339);

                            const past = now.subtract(.{ .days = 7 });
                            var past_buf: [30]u8 = undefined;
                            const past_fmt = try past.time().bufPrint(&past_buf, .rfc3339);

                            var buf: [128]u8 = undefined;
                            const targets = try std.fmt.bufPrint(
                                &buf,
                                "CHATHISTORY TARGETS timestamp={s} timestamp={s} 50\r\n",
                                .{ now_fmt, past_fmt },
                            );
                            try self.queueWrite(msg.client, targets);
                        },
                        .RPL_YOURHOST => {},
                        .RPL_CREATED => {},
                        .RPL_MYINFO => {},
                        .RPL_ISUPPORT => {
                            // syntax: <client> <token>[ <token>] :are supported
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue; // client
                            while (iter.next()) |token| {
                                if (mem.eql(u8, token, "WHOX"))
                                    msg.client.supports.whox = true
                                else if (mem.startsWith(u8, token, "PREFIX")) {
                                    const prefix = blk: {
                                        const idx = mem.indexOfScalar(u8, token, ')') orelse
                                            // default is "@+"
                                            break :blk try self.alloc.dupe(u8, "@+");
                                        break :blk try self.alloc.dupe(u8, token[idx + 1 ..]);
                                    };
                                    msg.client.supports.prefix = prefix;
                                }
                            }
                        },
                        .RPL_LOGGEDIN => {},
                        .RPL_TOPIC => {
                            // syntax: <client> <channel> :<topic>
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue :loop; // client ("*")
                            const channel_name = iter.next() orelse continue :loop; // channel
                            const topic = iter.next() orelse continue :loop; // topic

                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            if (channel.topic) |old_topic| {
                                self.alloc.free(old_topic);
                            }
                            channel.topic = try self.alloc.dupe(u8, topic);
                        },
                        .RPL_SASLSUCCESS => {},
                        .RPL_WHOREPLY => {
                            // syntax: <client> <channel> <username> <host> <server> <nick> <flags> :<hopcount> <real name>
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue :loop; // client
                            const channel_name = iter.next() orelse continue :loop; // channel
                            if (mem.eql(u8, channel_name, "*")) continue;
                            _ = iter.next() orelse continue :loop; // username
                            _ = iter.next() orelse continue :loop; // host
                            _ = iter.next() orelse continue :loop; // server
                            const nick = iter.next() orelse continue :loop; // nick
                            const flags = iter.next() orelse continue :loop; // nick

                            const user_ptr = try msg.client.getOrCreateUser(nick);
                            if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            try channel.addMember(user_ptr);
                        },
                        .RPL_WHOSPCRPL => {
                            // syntax: <client> <channel> <nick> <flags>
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue;
                            const channel_name = iter.next() orelse continue; // channel
                            const nick = iter.next() orelse continue;
                            const flags = iter.next() orelse continue;

                            const user_ptr = try msg.client.getOrCreateUser(nick);
                            if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            try channel.addMember(user_ptr);
                        },
                        .RPL_ENDOFWHO => {
                            // syntax: <client> <mask> :End of WHO list
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue :loop; // client
                            const channel_name = iter.next() orelse continue :loop; // channel
                            if (mem.eql(u8, channel_name, "*")) continue;
                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            channel.in_flight.who = false;
                        },
                        .RPL_NAMREPLY => {
                            // syntax: <client> <symbol> <channel> :[<prefix>]<nick>{ [<prefix>]<nick>}
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue; // client
                            _ = iter.next() orelse continue; // symbol
                            const channel_name = iter.next() orelse continue; // channel
                            const names = iter.next() orelse continue;
                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            var name_iter = std.mem.splitScalar(u8, names, ' ');
                            while (name_iter.next()) |name| {
                                const has_prefix = for (msg.client.supports.prefix) |ch| {
                                    if (name[0] == ch) break true;
                                } else false;

                                if (has_prefix) log.debug("HAS PREFIX {s}", .{name});
                                const user_ptr = if (has_prefix)
                                    try msg.client.getOrCreateUser(name[1..])
                                else
                                    try msg.client.getOrCreateUser(name);
                                try channel.addMember(user_ptr);
                            }
                        },
                        .RPL_ENDOFNAMES => {
                            // syntax: <client> <channel> :End of /NAMES list
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue; // client
                            const channel_name = iter.next() orelse continue; // channel
                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            channel.in_flight.names = false;
                        },
                        .BOUNCER => {
                            var iter = msg.paramIterator();
                            while (iter.next()) |param| {
                                if (mem.eql(u8, param, "NETWORK")) {
                                    const id = iter.next() orelse continue;
                                    const attr = iter.next() orelse continue;
                                    // check if we already have this network
                                    for (self.clients.items, 0..) |client, i| {
                                        if (client.config.network_id) |net_id| {
                                            if (mem.eql(u8, net_id, id)) {
                                                if (mem.eql(u8, attr, "*")) {
                                                    // * means the network was
                                                    // deleted
                                                    client.deinit();
                                                    _ = self.clients.swapRemove(i);
                                                }
                                                continue :loop;
                                            }
                                        }
                                    }

                                    var attr_iter = std.mem.splitScalar(u8, attr, ';');
                                    const name: ?[]const u8 = name: while (attr_iter.next()) |kv| {
                                        const n = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                                        if (mem.eql(u8, kv[0..n], "name"))
                                            break :name try self.alloc.dupe(u8, kv[n + 1 ..]);
                                    } else null;

                                    var cfg = msg.client.config;
                                    cfg.network_id = try self.alloc.dupe(u8, id);
                                    cfg.name = name;
                                    self.loop.?.postEvent(.{ .connect = cfg });
                                }
                            }
                        },
                        .AWAY => {
                            const src = msg.source orelse continue :loop;
                            var iter = msg.paramIterator();
                            const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                            const user = try msg.client.getOrCreateUser(src[0..n]);
                            // If there are any params, the user is away. Otherwise
                            // they are back.
                            user.away = if (iter.next()) |_| true else false;
                        },
                        .BATCH => {
                            var iter = msg.paramIterator();
                            const tag = iter.next() orelse continue;
                            switch (tag[0]) {
                                '+' => {
                                    const batch_type = iter.next() orelse continue;
                                    if (mem.eql(u8, batch_type, "chathistory")) {
                                        const target = iter.next() orelse continue;
                                        var channel = try msg.client.getOrCreateChannel(target);
                                        channel.at_oldest = true;
                                        const duped_tag = try self.alloc.dupe(u8, tag[1..]);
                                        try msg.client.batches.put(duped_tag, channel);
                                    }
                                },
                                '-' => {
                                    const key = msg.client.batches.getKey(tag[1..]) orelse continue;
                                    var chan = msg.client.batches.get(key) orelse @panic("key should exist here");
                                    chan.history_requested = false;
                                    _ = msg.client.batches.remove(key);
                                    self.alloc.free(key);
                                },
                                else => {},
                            }
                        },
                        .CHATHISTORY => {
                            var iter = msg.paramIterator();
                            const should_targets = iter.next() orelse continue;
                            if (!mem.eql(u8, should_targets, "TARGETS")) continue;
                            const target = iter.next() orelse continue;
                            // we only add direct messages, not more channels
                            assert(target.len > 0);
                            if (target[0] == '#') continue;

                            var channel = try msg.client.getOrCreateChannel(target);
                            const user_ptr = try msg.client.getOrCreateUser(target);
                            const me_ptr = try msg.client.getOrCreateUser(msg.client.config.nick);
                            try channel.addMember(user_ptr);
                            try channel.addMember(me_ptr);
                            // we set who_requested so we don't try to request
                            // who on DMs
                            channel.who_requested = true;
                            var buf: [128]u8 = undefined;
                            const mark_read = try std.fmt.bufPrint(
                                &buf,
                                "MARKREAD {s}\r\n",
                                .{channel.name},
                            );
                            try self.queueWrite(msg.client, mark_read);
                            try self.requestHistory(msg.client, .after, channel);
                        },
                        .JOIN => {
                            // get the user
                            const src = msg.source orelse continue :loop;
                            const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                            const user = try msg.client.getOrCreateUser(src[0..n]);

                            // get the channel
                            var iter = msg.paramIterator();
                            const target = iter.next() orelse continue;
                            var channel = try msg.client.getOrCreateChannel(target);

                            // If it's our nick, we request chat history
                            if (mem.eql(u8, user.nick, msg.client.config.nick))
                                try self.requestHistory(msg.client, .after, channel)
                            else
                                try channel.addMember(user);
                        },
                        .MARKREAD => {
                            var iter = msg.paramIterator();
                            const target = iter.next() orelse continue;
                            const timestamp = iter.next() orelse continue;
                            const equal = std.mem.indexOfScalar(u8, timestamp, '=') orelse continue;
                            const last_read = zeit.instant(.{
                                .source = .{
                                    .iso8601 = timestamp[equal + 1 ..],
                                },
                            }) catch |err| {
                                log.err("couldn't convert timestamp: {}", .{err});
                                continue;
                            };
                            var channel = try msg.client.getOrCreateChannel(target);
                            channel.last_read = last_read.unixTimestamp();
                            const last_msg = channel.messages.getLastOrNull() orelse continue;
                            const time = last_msg.time orelse continue;
                            if (time.instant().unixTimestamp() > channel.last_read)
                                channel.has_unread = true
                            else
                                channel.has_unread = false;
                        },
                        .PART => {
                            // get the user
                            const src = msg.source orelse continue :loop;
                            const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                            const user = try msg.client.getOrCreateUser(src[0..n]);

                            // get the channel
                            var iter = msg.paramIterator();
                            const target = iter.next() orelse continue;

                            if (mem.eql(u8, user.nick, msg.client.config.nick)) {
                                for (msg.client.channels.items, 0..) |channel, i| {
                                    if (!mem.eql(u8, channel.name, target)) continue;
                                    var chan = msg.client.channels.orderedRemove(i);
                                    chan.deinit(self.alloc);
                                    break;
                                }
                            } else {
                                const channel = try msg.client.getOrCreateChannel(target);
                                channel.removeMember(user);
                            }
                        },
                        .PRIVMSG, .NOTICE => {
                            keep_message = true;
                            // syntax: <target> :<message>
                            var iter = msg.paramIterator();
                            const target = blk: {
                                const tgt = iter.next() orelse continue;
                                if (mem.eql(u8, tgt, msg.client.config.nick)) {
                                    // If the target is us, it likely has our
                                    // hostname in it.
                                    const source = msg.source orelse continue;
                                    const n = mem.indexOfScalar(u8, source, '!') orelse source.len;
                                    break :blk source[0..n];
                                } else break :blk tgt;
                            };

                            // We handle batches separately. When we encounter a
                            // PRIVMSG from a batch, we use the original target
                            // from the batch start. We also never notify from a
                            // batched message. Batched messages also require
                            // sorting
                            var tag_iter = msg.tagIterator();
                            while (tag_iter.next()) |tag| {
                                if (mem.eql(u8, tag.key, "batch")) {
                                    const entry = msg.client.batches.getEntry(tag.value) orelse @panic("TODO");
                                    var channel = entry.value_ptr.*;
                                    try channel.messages.append(msg);
                                    std.sort.insertion(Message, channel.messages.items, {}, Message.compareTime);
                                    channel.at_oldest = false;
                                    const time = msg.time orelse continue;
                                    if (time.instant().unixTimestamp() > channel.last_read) {
                                        channel.has_unread = true;
                                        const content = iter.next() orelse continue;
                                        if (std.mem.indexOf(u8, content, msg.client.config.nick)) |_| {
                                            channel.has_unread_highlight = true;
                                        }
                                    }
                                    break;
                                }
                            } else {
                                // standard handling
                                var channel = try msg.client.getOrCreateChannel(target);
                                try channel.messages.append(msg);
                                const content = iter.next() orelse continue;
                                var has_highlight = false;
                                if (std.mem.indexOf(u8, content, msg.client.config.nick)) |_| {
                                    try self.vx.notify(writer, "comlink", content);
                                    has_highlight = true;
                                }
                                const time = msg.time orelse continue;
                                if (time.instant().unixTimestamp() > channel.last_read) {
                                    channel.has_unread_highlight = has_highlight;
                                    channel.has_unread = true;
                                }
                            }
                        },
                    }
                },
            }
        }

        try self.draw();
    }
}

/// fetch the history for the provided channel.
fn requestHistory(self: *App, client: *Client, cmd: ChatHistoryCommand, channel: *irc.Channel) !void {
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
        try self.queueWrite(client, hist);
        return;
    }

    switch (cmd) {
        .before => {
            assert(channel.messages.items.len > 0);
            const first = channel.messages.items[0];
            var tag_iter = first.tagIterator();
            const time = while (tag_iter.next()) |tag| {
                if (mem.eql(u8, tag.key, "time")) break tag.value;
            } else return error.NoTimeTag;
            const hist = try std.fmt.bufPrint(
                &buf,
                "CHATHISTORY BEFORE {s} timestamp={s} 50\r\n",
                .{ channel.name, time },
            );
            channel.history_requested = true;
            try self.queueWrite(client, hist);
        },
        .after => {
            assert(channel.messages.items.len > 0);
            const last = channel.messages.getLast();
            var tag_iter = last.tagIterator();
            const time = while (tag_iter.next()) |tag| {
                if (mem.eql(u8, tag.key, "time")) break tag.value;
            } else return error.NoTimeTag;
            const hist = try std.fmt.bufPrint(
                &buf,
                // we request 500 because we have no
                // idea how long we've been offline
                "CHATHISTORY AFTER {s} timestamp={s} 500\r\n",
                .{ channel.name, time },
            );
            channel.history_requested = true;
            try self.queueWrite(client, hist);
        },
    }
}

/// returns true if the mouse event occurred within this window
fn hasMouse(win: vaxis.Window, mouse: ?vaxis.Mouse) ?vaxis.Mouse {
    const event = mouse orelse return null;
    if (event.col >= win.x_off and
        event.col < (win.x_off + win.width) and
        event.row >= win.y_off and
        event.row < (win.y_off + win.height)) return event else return null;
}

/// generate vaxis.Segments for the message content
fn formatMessageContent(self: *App, msg: Message) !void {
    const ColorState = enum {
        ground,
        fg,
        bg,
    };
    const LinkState = enum {
        h,
        t1,
        t2,
        p,
        s,
        colon,
        slash,
        consume,
    };
    var iter = msg.paramIterator();
    _ = iter.next() orelse return error.InvalidMessage;
    const content = iter.next() orelse return error.InvalidMessage;
    var start: usize = 0;
    var i: usize = 0;
    var style: vaxis.Style = .{};
    while (i < content.len) : (i += 1) {
        const b = content[i];
        switch (b) {
            0x01 => {
                if (i == 0 and
                    content.len > 7 and
                    mem.startsWith(u8, content[1..], "ACTION"))
                {
                    // get the user of this message
                    const sender: []const u8 = blk: {
                        const src = msg.source orelse break :blk "";
                        const l = std.mem.indexOfScalar(u8, src, '!') orelse
                            std.mem.indexOfScalar(u8, src, '@') orelse
                            src.len;
                        break :blk src[0..l];
                    };
                    const user = try msg.client.getOrCreateUser(sender);
                    style.italic = true;
                    const user_style: vaxis.Style = .{
                        .fg = user.color,
                        .italic = true,
                    };
                    try self.content_segments.append(.{
                        .text = user.nick,
                        .style = user_style,
                    });
                    i += 6; // "ACTION"
                } else {
                    try self.content_segments.append(.{
                        .text = content[start..i],
                        .style = style,
                    });
                }
                start = i + 1;
            },
            0x02 => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.bold = !style.bold;
                start = i + 1;
            },
            0x03 => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                i += 1;
                var state: ColorState = .ground;
                var fg_idx: ?u8 = null;
                var bg_idx: ?u8 = null;
                while (i < content.len) : (i += 1) {
                    const d = content[i];
                    switch (state) {
                        .ground => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    state = .fg;
                                    fg_idx = d - '0';
                                },
                                else => {
                                    style.fg = .default;
                                    style.bg = .default;
                                    start = i;
                                    break;
                                },
                            }
                        },
                        .fg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const fg = fg_idx orelse 0;
                                    if (fg > 9) {
                                        style.fg = irc.toVaxisColor(fg);
                                        start = i;
                                        break;
                                    } else {
                                        fg_idx = fg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (fg_idx) |fg| {
                                        style.fg = irc.toVaxisColor(fg);
                                        start = i;
                                    }
                                    if (d == ',') state = .bg else break;
                                },
                            }
                        },
                        .bg => {
                            switch (d) {
                                '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                                    const bg = bg_idx orelse 0;
                                    if (i - start == 2) {
                                        style.bg = irc.toVaxisColor(bg);
                                        start = i;
                                        break;
                                    } else {
                                        bg_idx = bg * 10 + (d - '0');
                                    }
                                },
                                else => {
                                    if (bg_idx) |bg| {
                                        style.bg = irc.toVaxisColor(bg);
                                        start = i;
                                    }
                                    break;
                                },
                            }
                        },
                    }
                }
            },
            0x0F => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style = .{};
                start = i + 1;
            },
            0x16 => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.reverse = !style.reverse;
                start = i + 1;
            },
            0x1D => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.italic = !style.italic;
                start = i + 1;
            },
            0x1E => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });
                style.strikethrough = !style.strikethrough;
                start = i + 1;
            },
            0x1F => {
                try self.content_segments.append(.{
                    .text = content[start..i],
                    .style = style,
                });

                style.ul_style = if (style.ul_style == .off) .single else .off;
                start = i + 1;
            },
            else => {
                if (b == 'h') {
                    var state: LinkState = .h;
                    const h_start = i;
                    // consume until a space or EOF
                    i += 1;
                    while (i < content.len) : (i += 1) {
                        const b1 = content[i];
                        switch (state) {
                            .h => {
                                if (b1 == 't') state = .t1 else break;
                            },
                            .t1 => {
                                if (b1 == 't') state = .t2 else break;
                            },
                            .t2 => {
                                if (b1 == 'p') state = .p else break;
                            },
                            .p => {
                                if (b1 == 's')
                                    state = .s
                                else if (b1 == ':')
                                    state = .colon
                                else
                                    break;
                            },
                            .s => {
                                if (b1 == ':') state = .colon else break;
                            },
                            .colon => {
                                if (b1 == '/') state = .slash else break;
                            },
                            .slash => {
                                if (b1 == '/') {
                                    state = .consume;
                                    try self.content_segments.append(.{
                                        .text = content[start..h_start],
                                        .style = style,
                                    });
                                } else break;
                            },
                            .consume => {
                                if (b1 == ' ') {
                                    try self.content_segments.append(.{
                                        .text = content[h_start..i],
                                        .style = .{
                                            .fg = .{ .index = 4 },
                                        },
                                        .link = .{
                                            .uri = content[h_start..i],
                                        },
                                    });
                                    start = i;
                                    break;
                                } else if (i == content.len - 1) {
                                    try self.content_segments.append(.{
                                        .text = content[h_start..],
                                        .style = .{
                                            .fg = .{ .index = 4 },
                                        },
                                        .link = .{
                                            .uri = content[h_start..],
                                        },
                                    });
                                    return;
                                }
                            },
                        }
                    }
                }
            },
        }
    }
    if (start < i and start < content.len) {
        try self.content_segments.append(.{
            .text = content[start..],
            .style = style,
        });
    }
}

const Completer = struct {
    word: []const u8,
    start_idx: usize,
    options: std.ArrayList([]const u8),
    selected_idx: ?usize,
    widest: ?usize,
    buf: [irc.maximum_message_size]u8 = undefined,
    cmd: bool = false, // true when we are completing a command

    pub fn init(alloc: std.mem.Allocator, line: []const u8) !Completer {
        const start_idx = if (std.mem.lastIndexOfScalar(u8, line, ' ')) |idx| idx + 1 else 0;
        const last_word = line[start_idx..];
        var completer: Completer = .{
            .options = std.ArrayList([]const u8).init(alloc),
            .start_idx = start_idx,
            .word = last_word,
            .selected_idx = null,
            .widest = null,
        };
        @memcpy(completer.buf[0..line.len], line);
        if (last_word.len > 0 and last_word[0] == '/') {
            completer.cmd = true;
            try completer.findCommandMatches();
        }
        return completer;
    }

    pub fn deinit(self: *Completer) void {
        self.options.deinit();
    }

    /// cycles to the next option, returns the replacement text. Note that we
    /// start from the bottom, so a selected_idx = 0 means we are on _the last_
    /// item
    pub fn next(self: *Completer) []const u8 {
        if (self.options.items.len == 0) return "";
        {
            const last_idx = self.options.items.len - 1;
            if (self.selected_idx == null or self.selected_idx.? == last_idx)
                self.selected_idx = 0
            else
                self.selected_idx.? +|= 1;
        }
        return self.replacementText();
    }

    pub fn prev(self: *Completer) []const u8 {
        if (self.options.items.len == 0) return "";
        {
            const last_idx = self.options.items.len - 1;
            if (self.selected_idx == null or self.selected_idx.? == 0)
                self.selected_idx = last_idx
            else
                self.selected_idx.? -|= 1;
        }
        return self.replacementText();
    }

    pub fn replacementText(self: *Completer) []const u8 {
        if (self.selected_idx == null or self.options.items.len == 0) return "";
        const replacement = self.options.items[self.options.items.len - 1 - self.selected_idx.?];
        if (self.cmd) {
            self.buf[0] = '/';
            @memcpy(self.buf[1 .. 1 + replacement.len], replacement);
            const append_space = if (std.meta.stringToEnum(Command, replacement)) |cmd|
                cmd.appendSpace()
            else
                true;
            if (append_space) self.buf[1 + replacement.len] = ' ';
            return self.buf[0 .. 1 + replacement.len + @as(u1, if (append_space) 1 else 0)];
        }
        const start = self.start_idx;
        @memcpy(self.buf[start .. start + replacement.len], replacement);
        if (self.start_idx == 0) {
            @memcpy(self.buf[start + replacement.len .. start + replacement.len + 2], ": ");
            return self.buf[0 .. start + replacement.len + 2];
        } else {
            @memcpy(self.buf[start + replacement.len .. start + replacement.len + 1], " ");
            return self.buf[0 .. start + replacement.len + 1];
        }
    }

    pub fn findMatches(self: *Completer, chan: *irc.Channel) !void {
        if (self.options.items.len > 0) return;
        const alloc = self.options.allocator;
        var members = std.ArrayList(*irc.User).init(alloc);
        defer members.deinit();
        for (chan.members.items) |member| {
            if (std.ascii.startsWithIgnoreCase(member.nick, self.word)) {
                try members.append(member);
            }
        }
        std.sort.insertion(*irc.User, members.items, chan, irc.Channel.compareRecentMessages);
        self.options = try std.ArrayList([]const u8).initCapacity(alloc, members.items.len);
        for (members.items) |member| {
            try self.options.append(member.nick);
        }
    }

    pub fn findCommandMatches(self: *Completer) !void {
        if (self.options.items.len > 0) return;
        self.cmd = true;
        const commands = std.meta.fieldNames(Command);
        for (commands) |cmd| {
            if (std.ascii.startsWithIgnoreCase(cmd, self.word[1..])) {
                try self.options.append(cmd);
            }
        }
    }

    pub fn widestMatch(self: *Completer, win: vaxis.Window) usize {
        if (self.widest) |w| return w;
        var widest: usize = 0;
        for (self.options.items) |opt| {
            const width = win.gwidth(opt);
            if (width > widest) widest = width;
        }
        self.widest = widest;
        return widest;
    }

    pub fn numMatches(self: *Completer) usize {
        return self.options.items.len;
    }
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

    /// if we should append a space when completing
    pub fn appendSpace(self: Command) bool {
        return switch (self) {
            .quote,
            .join,
            .me,
            .msg,
            => true,
            else => false,
        };
    }
};

pub fn nextChannel(self: *App) void {
    const state = self.state.buffers;
    if (state.selected_idx >= state.count - 1)
        self.state.buffers.selected_idx = 0
    else
        self.state.buffers.selected_idx +|= 1;
}

pub fn prevChannel(self: *App) void {
    switch (self.state.buffers.selected_idx) {
        0 => self.state.buffers.selected_idx = self.state.buffers.count - 1,
        else => self.state.buffers.selected_idx -|= 1,
    }
}

/// handle a command
pub fn handleCommand(self: *App, buffer: Buffer, cmd: []const u8) !void {
    const command: Command = blk: {
        const start: u1 = if (cmd[0] == '/') 1 else 0;
        const end = mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
        break :blk std.meta.stringToEnum(Command, cmd[start..end]) orelse return error.UnknownCommand;
    };
    var buf: [1024]u8 = undefined;
    const client: *Client = switch (buffer) {
        .client => |client| client,
        .channel => |channel| channel.client,
    };
    const channel: ?*irc.Channel = switch (buffer) {
        .client => null,
        .channel => |channel| channel,
    };
    switch (command) {
        .quote => {
            const start = mem.indexOfScalar(u8, cmd, ' ') orelse return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(
                &buf,
                "{s}\r\n",
                .{cmd[start + 1 ..]},
            );
            return self.queueWrite(client, msg);
        },
        .join => {
            const start = std.mem.indexOfScalar(u8, cmd, ' ') orelse return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(
                &buf,
                "JOIN {s}\r\n",
                .{
                    cmd[start + 1 ..],
                },
            );
            return self.queueWrite(client, msg);
        },
        .me => {
            if (channel == null) return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(
                &buf,
                "PRIVMSG {s} :\x01ACTION {s}\x01\r\n",
                .{
                    channel.?.name,
                    cmd[4..],
                },
            );
            return self.queueWrite(client, msg);
        },
        .msg => {
            //syntax: /msg <nick> <msg>
            const s = std.mem.indexOfScalar(u8, cmd, ' ') orelse return error.InvalidCommand;
            const e = std.mem.indexOfScalarPos(u8, cmd, s + 1, ' ') orelse return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(
                &buf,
                "PRIVMSG {s} :{s}\r\n",
                .{
                    cmd[s + 1 .. e],
                    cmd[e + 1 ..],
                },
            );
            return self.queueWrite(client, msg);
        },
        .names => {
            if (channel == null) return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(&buf, "NAMES {s}\r\n", .{channel.?.name});
            return self.queueWrite(client, msg);
        },
        .@"next-channel" => self.nextChannel(),
        .@"prev-channel" => self.prevChannel(),
        .quit => self.should_quit = true,
        .who => {
            if (channel == null) return error.InvalidCommand;
            const msg = try std.fmt.bufPrint(
                &buf,
                "WHO {s}\r\n",
                .{
                    channel.?.name,
                },
            );
            return self.queueWrite(client, msg);
        },
    }
}

pub fn whox(self: *App, client: *Client, channel: *irc.Channel) !void {
    channel.who_requested = true;
    if (channel.name.len > 0 and
        channel.name[0] != '#')
    {
        const other = try client.getOrCreateUser(channel.name);
        const me = try client.getOrCreateUser(client.config.nick);
        try channel.addMember(other);
        try channel.addMember(me);
        return;
    }
    // Only use WHO if we have WHOX and away-notify. Without
    // WHOX, we can get rate limited on eg. libera. Without
    // away-notify, our list will become stale
    if (client.supports.whox and
        client.caps.@"away-notify" and
        !channel.in_flight.who)
    {
        var write_buf: [64]u8 = undefined;
        channel.in_flight.who = true;
        const who = try std.fmt.bufPrint(
            &write_buf,
            "WHO {s} %cnf\r\n",
            .{channel.name},
        );
        try self.queueWrite(client, who);
    } else {
        var write_buf: [64]u8 = undefined;
        channel.in_flight.names = true;
        const names = try std.fmt.bufPrint(
            &write_buf,
            "NAMES {s}\r\n",
            .{channel.name},
        );
        try self.queueWrite(client, names);
    }
}

pub fn selectedBuffer(self: *App) ?Buffer {
    var i: usize = 0;
    for (self.clients.items) |client| {
        if (i == self.state.buffers.selected_idx) return .{ .client = client };
        i += 1;
        for (client.channels.items) |*channel| {
            if (i == self.state.buffers.selected_idx) return .{ .channel = channel };
            i += 1;
        }
    }
    return null;
}

fn draw(self: *App) !void {

    // reset window state
    const win = self.vx.window();
    win.clear();
    self.vx.setMouseShape(.default);

    if (self.state.mouse) |mouse| {
        if (self.state.buffers.resizing) {
            self.state.buffers.width = @min(mouse.col, win.width -| self.state.members.width);
        } else if (self.state.members.resizing) {
            self.state.members.width = win.width -| mouse.col + 1;
        }

        if (mouse.col == self.state.buffers.width) {
            self.vx.setMouseShape(.@"ew-resize");
            switch (mouse.type) {
                .press => {
                    if (mouse.button == .left) self.state.buffers.resizing = true;
                },
                .release => self.state.buffers.resizing = false,
                else => {},
            }
        } else if (mouse.col == win.width -| self.state.members.width + 1) {
            self.vx.setMouseShape(.@"ew-resize");
            switch (mouse.type) {
                .press => {
                    if (mouse.button == .left) self.state.members.resizing = true;
                },
                .release => self.state.members.resizing = false,
                else => {},
            }
        }
    }

    const buf_list_w = self.state.buffers.width;
    const mbr_list_w = self.state.members.width;
    const message_list_width = win.width -| buf_list_w -| mbr_list_w;

    const channel_list_win = win.child(.{
        .width = .{ .limit = self.state.buffers.width + 1 },
        .border = .{ .where = .right },
    });

    const member_list_win = win.child(.{
        .x_off = buf_list_w + message_list_width + 1,
        .border = .{ .where = .left },
    });

    const middle_win = win.child(.{
        .x_off = buf_list_w + 1,
        .width = .{ .limit = message_list_width },
    });

    const topic_win = middle_win.child(.{
        .height = .{ .limit = 2 },
        .border = .{ .where = .bottom },
    });

    var row: usize = 0;
    for (self.clients.items) |client| {
        var style: vaxis.Style = if (row == self.state.buffers.selected_idx)
            .{
                .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                .reverse = true,
            }
        else
            .{
                .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
            };
        const network_win = channel_list_win.child(.{
            .y_off = row,
            .height = .{ .limit = 1 },
        });
        if (network_win.hasMouse(self.state.mouse)) |_| {
            self.vx.setMouseShape(.pointer);
            style.bg = .{ .index = 8 };
        }
        _ = try network_win.print(
            &.{.{
                .text = client.config.name orelse client.config.server,
                .style = style,
            }},
            .{},
        );
        if (network_win.hasMouse(self.state.mouse)) |_| {
            self.vx.setMouseShape(.pointer);
        }
        row += 1;

        for (client.channels.items) |*channel| {
            const channel_win = channel_list_win.child(.{
                .y_off = row,
                .height = .{ .limit = 1 },
            });
            if (channel_win.hasMouse(self.state.mouse)) |mouse| {
                if (mouse.type == .press and mouse.button == .left) {
                    self.state.buffers.selected_idx = row;
                    self.loop.?.postEvent(.redraw);
                }
            }
            var chan_style: vaxis.Style = if (row == self.state.buffers.selected_idx)
                .{
                    .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                    .reverse = true,
                }
            else if (channel.has_unread)
                .{
                    .fg = .{ .index = 4 },
                    .bold = true,
                }
            else
                .{
                    .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                };
            defer row += 1;
            const prefix: []const u8 = if (channel.name[0] == '#') "#" else "";
            const name_offset: usize = if (prefix.len > 0) 1 else 0;

            if (channel_win.hasMouse(self.state.mouse)) |mouse| {
                self.vx.setMouseShape(.pointer);
                if (mouse.button == .left)
                    chan_style.reverse = true
                else
                    chan_style.bg = .{ .index = 8 };
            }

            const first_seg: vaxis.Segment = if (channel.has_unread_highlight)
                .{ .text = " ●︎", .style = .{ .fg = .{ .index = 1 } } }
            else
                .{ .text = "  " };

            var chan_seg = [_]vaxis.Segment{
                first_seg,
                .{
                    .text = prefix,
                    .style = .{ .fg = .{ .index = 8 } },
                },
                .{
                    .text = channel.name[name_offset..],
                    .style = chan_style,
                },
            };
            const result = try channel_win.print(
                &chan_seg,
                .{},
            );
            if (result.overflow)
                channel_list_win.writeCell(
                    buf_list_w -| 1,
                    row,
                    .{
                        .char = .{
                            .grapheme = "…",
                            .width = 1,
                        },
                        .style = chan_style,
                    },
                );
            if (row == self.state.buffers.selected_idx) {
                var write_buf: [128]u8 = undefined;
                if (channel.has_unread) {
                    channel.has_unread = false;
                    channel.has_unread_highlight = false;
                    const last_msg = channel.messages.getLast();
                    var tag_iter = last_msg.tagIterator();
                    while (tag_iter.next()) |tag| {
                        if (!std.mem.eql(u8, tag.key, "time")) continue;
                        const mark_read = try std.fmt.bufPrint(
                            &write_buf,
                            "MARKREAD {s} timestamp={s}\r\n",
                            .{
                                channel.name,
                                tag.value,
                            },
                        );
                        try self.queueWrite(client, mark_read);
                    }
                }
                if (!channel.who_requested) try self.whox(client, channel);
                var topic_seg = [_]vaxis.Segment{
                    .{
                        .text = channel.topic orelse "",
                    },
                };
                _ = try topic_win.print(&topic_seg, .{ .wrap = .none });

                if (hasMouse(member_list_win, self.state.mouse)) |mouse| {
                    switch (mouse.button) {
                        .wheel_up => {
                            self.state.members.scroll_offset -|= 3;
                            self.state.mouse.?.button = .none;
                        },
                        .wheel_down => {
                            self.state.members.scroll_offset +|= 3;
                            self.state.mouse.?.button = .none;
                        },
                        else => {},
                    }
                }

                self.state.members.scroll_offset = @min(self.state.members.scroll_offset, channel.members.items.len -| member_list_win.height);

                var member_row: usize = 0;
                for (channel.members.items) |member| {
                    defer member_row += 1;
                    if (member_row < self.state.members.scroll_offset) continue;
                    var member_seg = [_]vaxis.Segment{
                        .{
                            .text = " ",
                        },
                        .{
                            .text = member.nick,
                            .style = .{
                                .fg = if (member.away)
                                    .{ .index = 8 }
                                else
                                    member.color,
                            },
                        },
                    };
                    _ = try member_list_win.print(
                        &member_seg,
                        .{
                            .row_offset = member_row - self.state.members.scroll_offset,
                        },
                    );
                }

                // loop the messages and print from the last line to current
                // line
                const message_list_win = middle_win.child(.{
                    .y_off = 2,
                    .height = .{ .limit = middle_win.height -| 3 },
                    .width = .{ .limit = middle_win.width -| 1 },
                });
                if (hasMouse(message_list_win, self.state.mouse)) |mouse| {
                    switch (mouse.button) {
                        .wheel_up => {
                            self.state.messages.scroll_offset +|= 3;
                            self.state.mouse.?.button = .none;
                        },
                        .wheel_down => {
                            self.state.messages.scroll_offset -|= 3;
                            self.state.mouse.?.button = .none;
                        },
                        else => {},
                    }
                }
                self.state.messages.scroll_offset = @min(self.state.messages.scroll_offset, channel.messages.items.len -| 1);
                const message_offset_win = message_list_win.child(.{
                    .x_off = 6,
                });

                var prev_sender: ?[]const u8 = null;
                var i: usize = channel.messages.items.len -| self.state.messages.scroll_offset;
                var y_off: usize = message_list_win.height -| 1;
                while (i > 0) {
                    i -= 1;
                    var message = channel.messages.items[i];
                    // syntax: <target> <message>

                    const sender: []const u8 = blk: {
                        const src = message.source orelse break :blk "";
                        const l = std.mem.indexOfScalar(u8, src, '!') orelse
                            std.mem.indexOfScalar(u8, src, '@') orelse
                            src.len;
                        break :blk src[0..l];
                    };
                    {
                        // If this sender is not the same as the previous printed
                        // message, then we'll print the previous sender and keep
                        // going
                        defer prev_sender = sender;
                        if (prev_sender != null and
                            !mem.eql(u8, sender, prev_sender.?) and
                            y_off > 0)
                        {
                            y_off -|= 1;
                            const user = try client.getOrCreateUser(prev_sender.?);
                            const sender_win = message_list_win.child(.{
                                .x_off = 6,
                                .y_off = y_off,
                                .height = .{ .limit = 1 },
                            });
                            const sender_result = try sender_win.print(
                                &.{.{
                                    .text = prev_sender.?,
                                    .style = .{
                                        .fg = user.color,
                                        .bold = true,
                                    },
                                }},
                                .{ .wrap = .word },
                            );
                            y_off -|= 1;
                            const result_win = sender_win.child(.{ .width = .{ .limit = sender_result.col } });
                            if (result_win.hasMouse(self.state.mouse)) |_| {
                                self.vx.setMouseShape(.pointer);
                            }
                        }
                    }

                    if (y_off == 0) break;

                    try self.formatMessageContent(message);
                    defer self.content_segments.clearRetainingCapacity();
                    // print the content first
                    const print_result = try message_offset_win.print(self.content_segments.items, .{
                        .wrap = .word,
                        .commit = false,
                    });
                    const content_height = if (print_result.col == 0)
                        print_result.row
                    else
                        print_result.row + 1;

                    const height = if (content_height > y_off) content_height - y_off else content_height;
                    if (height == 0) break;
                    const content_win = message_offset_win.child(
                        .{
                            .y_off = y_off -| content_height,
                            .height = .{ .limit = height },
                        },
                    );
                    if (hasMouse(content_win, self.state.mouse)) |mouse| {
                        var bg_idx: u8 = 8;
                        if (mouse.type == .press and mouse.button == .middle) {
                            var list = std.ArrayList(u8).init(self.alloc);
                            defer list.deinit();
                            for (self.content_segments.items) |item| {
                                try list.appendSlice(item.text);
                            }
                            try self.vx.copyToSystemClipboard(self.tty.anyWriter(), list.items, self.alloc);
                            bg_idx = 3;
                        }
                        content_win.fill(.{
                            .char = .{
                                .grapheme = " ",
                                .width = 1,
                            },
                            .style = .{
                                .bg = .{ .index = bg_idx },
                            },
                        });
                        for (self.content_segments.items) |*item| {
                            item.style.bg = .{ .index = bg_idx };
                        }
                    }
                    var iter = message.paramIterator();
                    // target is the channel, and we already handled that
                    _ = iter.next() orelse continue;

                    const content = iter.next() orelse continue;
                    if (std.mem.indexOf(u8, content, client.config.nick)) |_| {
                        for (self.content_segments.items) |*item| {
                            if (item.style.fg == .default)
                                item.style.fg = .{ .index = 3 };
                        }
                    }
                    _ = try content_win.print(
                        self.content_segments.items,
                        .{
                            .wrap = .word,
                            // .skip_n_rows = content_height - content_win.height,
                        },
                    );
                    if (content_height > y_off) break;
                    const gutter = message_list_win.child(.{
                        .y_off = y_off -| content_height,
                        .width = .{ .limit = 6 },
                    });

                    if (message.time_buf) |buf| {
                        var date: bool = false;
                        if (i != 0 and channel.messages.items[i - 1].time != null) {
                            const time = message.time.?;
                            const prev = channel.messages.items[i - 1].time.?;
                            if (time.day != prev.day) {
                                date = true;
                                message.time_buf = try std.fmt.bufPrint(
                                    message.time_buf.?,
                                    "{d:0>2}/{d:0>2}",
                                    .{ @intFromEnum(time.month), time.day },
                                );
                            }
                        }
                        if (i == 0) {
                            date = true;
                            message.time_buf = try std.fmt.bufPrint(
                                message.time_buf.?,
                                "{d:0>2}/{d:0>2}",
                                .{ @intFromEnum(message.time.?.month), message.time.?.day },
                            );
                        }
                        const fg: vaxis.Color = if (date)
                            .default
                        else
                            .{ .index = 8 };
                        var time_seg = [_]vaxis.Segment{
                            .{
                                .text = buf,
                                .style = .{ .fg = fg },
                            },
                        };
                        _ = try gutter.print(&time_seg, .{});
                    }

                    y_off -|= content_height;

                    // If we are on the first message, print the sender
                    if (i == 0) {
                        y_off -|= 1;
                        const user = try client.getOrCreateUser(sender);
                        const sender_win = message_list_win.child(.{
                            .x_off = 6,
                            .y_off = y_off,
                            .height = .{ .limit = 1 },
                        });
                        const sender_result = try sender_win.print(
                            &.{.{
                                .text = sender,
                                .style = .{
                                    .fg = user.color,
                                    .bold = true,
                                },
                            }},
                            .{ .wrap = .word },
                        );
                        const result_win = sender_win.child(.{ .width = .{ .limit = sender_result.col } });
                        if (result_win.hasMouse(self.state.mouse)) |_| {
                            self.vx.setMouseShape(.pointer);
                        }
                    }

                    // if we are on the oldest message, request more history
                    if (i == 0 and !channel.at_oldest) {
                        try self.requestHistory(client, .before, channel);
                    }
                }
                {
                    // draw a scrollbar
                    var scrollbar: vaxis.widgets.Scrollbar = .{
                        .total = channel.messages.items.len,
                        .view_size = channel.messages.items.len -| self.state.messages.scroll_offset -| i,
                        .top = i,
                    };
                    const scrollbar_win = middle_win.child(.{
                        .x_off = message_list_win.width,
                        .y_off = 2,
                        .height = .{ .limit = middle_win.height -| 3 },
                    });
                    scrollbar.draw(scrollbar_win);
                }
                if (self.completer) |*completer| {
                    try completer.findMatches(channel);

                    var completion_style: vaxis.Style = .{ .bg = .{ .index = 8 } };
                    const completion_win = middle_win.child(.{
                        .width = .{ .limit = completer.widestMatch(win) + 1 },
                        .height = .{ .limit = @min(completer.numMatches(), middle_win.height -| 1) },
                        .x_off = completer.start_idx,
                        .y_off = middle_win.height -| completer.numMatches() -| 1,
                    });
                    completion_win.fill(.{
                        .char = .{ .grapheme = " ", .width = 1 },
                        .style = completion_style,
                    });
                    var completion_row: usize = 0;
                    while (completion_row < completion_win.height) : (completion_row += 1) {
                        log.debug("COMPLETION ROW {d}, selected_idx {d}", .{ completion_row, completer.selected_idx orelse 0 });
                        if (completer.selected_idx) |idx| {
                            if (completion_row == idx)
                                completion_style.reverse = true
                            else {
                                completion_style = .{ .bg = .{ .index = 8 } };
                            }
                        }
                        var seg = [_]vaxis.Segment{
                            .{
                                .text = completer.options.items[completer.options.items.len - 1 - completion_row],
                                .style = completion_style,
                            },
                            .{
                                .text = " ",
                                .style = completion_style,
                            },
                        };
                        _ = try completion_win.print(&seg, .{
                            .row_offset = completion_win.height -| completion_row -| 1,
                        });
                    }
                }
            }
        }
    }

    const input_win = middle_win.child(.{
        .y_off = win.height -| 1,
        .width = .{ .limit = middle_win.width -| 7 },
        .height = .{ .limit = 1 },
    });
    const len_win = middle_win.child(.{
        .x_off = input_win.width,
        .y_off = win.height -| 1,
        .width = .{ .limit = 7 },
        .height = .{ .limit = 1 },
    });
    const buf_name_len = blk: {
        const sel_buf = self.selectedBuffer() orelse @panic("no buffer");
        switch (sel_buf) {
            .channel => |chan| break :blk chan.name.len,
            else => break :blk 0,
        }
    };
    // PRIVMSG <channel_name> :<message>\r\n = 12 bytes of overhead
    const max_len = irc.maximum_message_size - buf_name_len - 12;
    var len_buf: [7]u8 = undefined;
    const msg_len = self.input.buf.realLength();
    _ = try std.fmt.bufPrint(&len_buf, "{d: >3}/{d}", .{ msg_len, max_len });

    var len_segs = [_]vaxis.Segment{
        .{
            .text = len_buf[0..3],
            .style = .{ .fg = if (msg_len > max_len)
                .{ .index = 1 }
            else
                .{ .index = 8 } },
        },
        .{
            .text = len_buf[3..],
            .style = .{ .fg = .{ .index = 8 } },
        },
    };

    _ = try len_win.print(&len_segs, .{});
    self.input.draw(input_win);

    if (self.state.paste.showDialog()) {
        // Draw a modal dialog for how to handle multi-line paste
        const multiline_paste_win = vaxis.widgets.alignment.center(win, win.width - 10, win.height - 10);
        const bordered = vaxis.widgets.border.all(multiline_paste_win, .{});
        bordered.clear();
        const warning_width: usize = 37;
        const title_win = multiline_paste_win.child(.{
            .height = .{ .limit = 2 },
            .y_off = 1,
            .x_off = multiline_paste_win.width / 2 - warning_width / 2,
        });
        const title_seg = [_]vaxis.Segment{
            .{
                .text = "/!\\ Warning: Multiline paste detected",
                .style = .{
                    .fg = .{ .index = 3 },
                    .bold = true,
                },
            },
        };
        _ = try title_win.print(&title_seg, .{ .wrap = .none });
        var segs = [_]vaxis.Segment{
            .{ .text = self.paste_buffer.items },
        };
        _ = try bordered.print(&segs, .{ .wrap = .grapheme, .row_offset = 2 });
        const button: Button = .{
            .label = "Accept",
            .style = .{ .bg = .{ .index = 7 } },
        };
        try button.draw(bordered.child(.{
            .x_off = 3,
            .y_off = bordered.height - 4,
            .height = .{ .limit = 3 },
            .width = .{ .limit = 10 },
        }));
    }

    self.state.buffers.count = row;

    var buffered = self.tty.bufferedWriter();
    try self.vx.render(buffered.writer().any());
    try buffered.flush();
}
