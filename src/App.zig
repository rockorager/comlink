const std = @import("std");
const vaxis = @import("vaxis");
const zeit = @import("zeit");
const ziglua = @import("ziglua");
const ziglyph = vaxis.ziglyph;

const assert = std.debug.assert;
const base64 = std.base64.standard.Encoder;
const mem = std.mem;

const irc = @import("irc.zig");
const lua = @import("lua.zig");
const strings = @import("strings.zig");

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
};

pub const WriteRequest = struct {
    client: *Client,
    msg: []const u8,
};

const ChatHistoryCommand = enum {
    before,
    after,
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
lua: Lua,

/// the vaxis instance for our application
vx: vaxis.Vaxis(Event),

/// our queue of writes
write_queue: vaxis.Queue(WriteRequest, 128) = .{},

state: State = .{},

content_segments: std.ArrayList(vaxis.Segment),

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
};

/// initialize vaxis, lua state
pub fn init(alloc: std.mem.Allocator) !App {
    var app: App = .{
        .alloc = alloc,
        .clients = std.ArrayList(*Client).init(alloc),
        .lua = try Lua.init(&alloc),
        .vx = try vaxis.init(Event, .{}),
        .content_segments = std.ArrayList(vaxis.Segment).init(alloc),
    };

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

    // close vaxis
    {
        self.vx.stopReadThread();
        self.vx.deinit(self.alloc);
    }

    self.lua.deinit();
    self.bundle.deinit(self.alloc);
    // drain the queue
    while (self.vx.queue.tryPop()) |event| {
        switch (event) {
            .message => |msg| msg.deinit(self.alloc),
            else => {},
        }
    }

    self.content_segments.deinit();
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
    {
        try self.vx.startReadThread();
        try self.vx.enterAltScreen();
        try self.vx.queryTerminal();
        try self.vx.setMouseMode(true);
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
        self.lua.setField(-2, "zirconium"); // [package, preload]
        // empty the stack
        self.lua.pop(2); // []

        // keep a reference to our app in the lua state
        self.lua.pushLightUserdata(self); // [userdata]
        self.lua.setField(lua.registry_index, lua.app_key); // []

        // load config
        self.lua.doFile("/home/tim/.config/zirconium/init.lua") catch return error.LuaError;
    }

    var input = vaxis.widgets.TextInput.init(self.alloc);
    defer input.deinit();

    loop: while (true) {
        self.vx.pollEvent();
        while (self.vx.queue.tryPop()) |event| {
            switch (event) {
                .redraw => {},
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        return;
                    } else if (key.matches(vaxis.Key.down, .{ .alt = true })) {
                        const state = self.state.buffers;
                        if (state.selected_idx >= state.count - 1)
                            self.state.buffers.selected_idx = 0
                        else
                            self.state.buffers.selected_idx +|= 1;
                    } else if (key.matches(vaxis.Key.up, .{ .alt = true })) {
                        if (self.state.buffers.selected_idx == 0)
                            self.state.buffers.selected_idx = self.state.buffers.count - 1
                        else
                            self.state.buffers.selected_idx -|= 1;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (input.buf.items.len == 0) continue;

                        var i: usize = 0;
                        for (self.clients.items) |client| {
                            i += 1;
                            for (client.channels.items) |channel| {
                                defer i += 1;
                                if (i != self.state.buffers.selected_idx) continue;

                                var buf: [1024]u8 = undefined;
                                const content = try input.toOwnedSlice();
                                defer self.alloc.free(content);
                                const msg = if (content[0] == '/')
                                    try std.fmt.bufPrint(
                                        &buf,
                                        "{s}\r\n",
                                        .{
                                            content[1..],
                                        },
                                    )
                                else
                                    try std.fmt.bufPrint(
                                        &buf,
                                        "PRIVMSG {s} :{s}\r\n",
                                        .{
                                            channel.name,
                                            content,
                                        },
                                    );
                                try self.queueWrite(client, msg);
                            }
                        }
                    } else {
                        try input.update(.{ .key_press = key });
                    }
                },
                .focus_out => self.state.mouse = null,
                .mouse => |mouse| {
                    self.state.mouse = mouse;
                    log.debug("mouse event: {}", .{mouse});
                },
                .winsize => |ws| try self.vx.resize(self.alloc, ws),
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
                            var iter = msg.paramIterator();
                            while (iter.next()) |param| {
                                if (mem.eql(u8, param, "ACK")) {
                                    const caps = iter.next() orelse continue;
                                    // When we get an ACK for sasl, we initiate
                                    // authentication
                                    if (mem.indexOf(u8, caps, "sasl")) |_| {
                                        try self.queueWrite(msg.client, "AUTHENTICATE PLAIN\r\n");
                                    }
                                }
                                if (mem.eql(u8, param, "NAK")) {
                                    log.err("CAP not supported {s}", .{iter.next().?});
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
                        .RPL_ISUPPORT => {},
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
                        .RPL_NAMREPLY => {},
                        .RPL_ENDOFNAMES => {},
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
                                    self.vx.postEvent(.{ .connect = cfg });
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
                                        const duped_tag = try self.alloc.dupe(u8, tag[1..]);
                                        try channel.batches.put(duped_tag, false);
                                    }
                                },
                                '-' => {
                                    for (msg.client.channels.items) |*chan| {
                                        const key = chan.batches.getKey(tag[1..]) orelse continue;
                                        const recv_hist = chan.batches.get(key) orelse unreachable;
                                        _ = chan.batches.remove(key);
                                        self.alloc.free(key);
                                        chan.history_requested = false;
                                        if (!recv_hist) chan.at_oldest = true;
                                        break;
                                    }
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

                            // If it's our nick, we WHO and CHATHISTORY the
                            // channel, otherwise we just add the user to the
                            // channel list
                            if (mem.eql(u8, user.nick, msg.client.config.nick)) {
                                var buf: [128]u8 = undefined;
                                const who = try std.fmt.bufPrint(
                                    &buf,
                                    "WHO {s}\r\n",
                                    .{channel.name},
                                );
                                try self.queueWrite(msg.client, who);

                                try self.requestHistory(msg.client, .after, channel);
                            } else {
                                try channel.addMember(user);
                            }
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
                        .PRIVMSG => {
                            keep_message = true;
                            // syntax: <target> :<message>
                            var iter = msg.paramIterator();
                            const target = blk: {
                                const tgt = iter.next() orelse continue;
                                if (mem.eql(u8, tgt, msg.client.config.nick))
                                    break :blk msg.source orelse continue
                                else
                                    break :blk tgt;
                            };
                            var channel = try msg.client.getOrCreateChannel(target);
                            try channel.messages.append(msg);
                            var tag_iter = msg.tagIterator();
                            const batch: bool = while (tag_iter.next()) |tag| {
                                if (mem.eql(u8, tag.key, "batch")) {
                                    std.sort.insertion(Message, channel.messages.items, {}, Message.compareTime);
                                    const key = channel.batches.getKey(tag.value) orelse continue;
                                    try channel.batches.put(key, true);
                                    break true;
                                }
                            } else false;
                            if (!batch) {
                                const content = iter.next() orelse continue;
                                if (std.mem.indexOf(u8, content, msg.client.config.nick)) |_| {
                                    try self.vx.notify("zirconium", content);
                                }
                            }
                            const time = msg.time orelse continue;
                            if (time.instant().unixTimestamp() > channel.last_read)
                                channel.has_unread = true;
                        },
                    }
                },
            }
        }

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
                    .press => self.state.buffers.resizing = true,
                    .release => self.state.buffers.resizing = false,
                    else => {},
                }
            } else if (mouse.col == win.width - self.state.members.width + 1) {
                self.vx.setMouseShape(.@"ew-resize");
                switch (mouse.type) {
                    .press => self.state.members.resizing = true,
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
            const style: vaxis.Style = if (row == self.state.buffers.selected_idx)
                .{
                    .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                    .reverse = true,
                }
            else
                .{
                    .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                };
            var segs = [_]vaxis.Segment{
                .{
                    .text = client.config.name orelse client.config.server,
                    .style = style,
                },
            };
            _ = try channel_list_win.print(
                &segs,
                .{ .row_offset = row },
            );
            row += 1;

            for (client.channels.items) |*channel| {
                const chan_style: vaxis.Style = if (row == self.state.buffers.selected_idx)
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
                var chan_seg = [_]vaxis.Segment{
                    .{
                        .text = "  ",
                    },
                    .{
                        .text = channel.name,
                        .style = chan_style,
                    },
                };
                const overflow = try channel_list_win.print(
                    &chan_seg,
                    .{
                        .row_offset = row,
                        .wrap = .none,
                    },
                );
                if (overflow)
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
                    if (channel.has_unread) {
                        channel.has_unread = false;
                        const last_msg = channel.messages.getLast();
                        var tag_iter = last_msg.tagIterator();
                        while (tag_iter.next()) |tag| {
                            if (!std.mem.eql(u8, tag.key, "time")) continue;
                            var buf: [128]u8 = undefined;
                            const mark_read = try std.fmt.bufPrint(
                                &buf,
                                "MARKREAD {s} timestamp={s}\r\n",
                                .{
                                    channel.name,
                                    tag.value,
                                },
                            );
                            try self.queueWrite(client, mark_read);
                        }
                    }
                    var topic_seg = [_]vaxis.Segment{
                        .{
                            .text = channel.topic orelse "",
                        },
                    };
                    _ = try topic_win.print(&topic_seg, .{ .wrap = .none });
                    var member_row: usize = 0;

                    for (channel.members.items) |member| {
                        defer member_row += 1;
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
                                .row_offset = member_row,
                            },
                        );
                    }

                    // loop the messages and print from the last line to current
                    // line
                    var i: usize = channel.messages.items.len -| self.state.messages.scroll_offset;
                    var h: usize = 0;
                    const message_list_win = middle_win.initChild(
                        0,
                        2,
                        .expand,
                        .{ .limit = middle_win.height -| 3 },
                    );
                    if (hasMouse(message_list_win, self.state.mouse)) |mouse| {
                        switch (mouse.button) {
                            .wheel_up => {
                                self.state.messages.scroll_offset +|= 1;
                                self.state.mouse.?.button = .none;
                            },
                            .wheel_down => {
                                self.state.messages.scroll_offset -|= 1;
                                self.state.mouse.?.button = .none;
                            },
                            else => {},
                        }
                    }
                    const message_offset_win = message_list_win.initChild(
                        6,
                        0,
                        .expand,
                        .expand,
                    );
                    var prev_sender: []const u8 = "";
                    var sender_win: ?vaxis.Window = null;
                    while (i > 0) {
                        i -= 1;
                        const message = channel.messages.items[i];
                        // if we are on the oldest message, request more history
                        if (i == 0 and !channel.at_oldest) {
                            try self.requestHistory(client, .before, channel);
                        }
                        // syntax: <target> <message>
                        var iter = message.paramIterator();
                        // target is the channel, and we already handled that
                        _ = iter.next() orelse continue;

                        // if this is the same sender, we will clear the last
                        // sender_win and reduce one from the row we are
                        // printing on
                        const sender: []const u8 = blk: {
                            const src = message.source orelse break :blk "";
                            const l = std.mem.indexOfScalar(u8, src, '!') orelse
                                std.mem.indexOfScalar(u8, src, '@') orelse
                                src.len;
                            break :blk src[0..l];
                        };
                        if (sender_win != null and mem.eql(u8, sender, prev_sender)) {
                            sender_win.?.clear();
                            h -= 2;
                        }

                        try self.formatMessageContent(message);
                        defer self.content_segments.clearRetainingCapacity();
                        const user = try client.getOrCreateUser(sender);
                        // print the content first
                        const n = strings.lineCountForWindow(message_offset_win, self.content_segments.items) + 1;
                        h += n;
                        const content_win = message_offset_win.initChild(
                            0,
                            message_offset_win.height -| h,
                            .expand,
                            .{ .limit = n - 1 },
                        );
                        if (hasMouse(content_win, self.state.mouse)) |_| {
                            content_win.fill(.{
                                .char = .{
                                    .grapheme = " ",
                                    .width = 1,
                                },
                                .style = .{
                                    .bg = .{ .index = 8 },
                                },
                            });
                            for (self.content_segments.items) |*item| {
                                item.style.bg = .{ .index = 8 };
                            }
                        }
                        _ = try content_win.print(
                            self.content_segments.items,
                            .{ .wrap = .word },
                        );
                        const gutter = message_list_win.initChild(
                            0,
                            message_list_win.height -| h,
                            .{ .limit = 5 },
                            .{ .limit = h },
                        );

                        // print the sender
                        defer prev_sender = sender;
                        if (h >= message_list_win.height) break;

                        h += 1;

                        if (message.time_buf) |buf| {
                            var time_seg = [_]vaxis.Segment{
                                .{
                                    .text = buf,
                                    .style = .{ .fg = .{ .index = 8 } },
                                },
                            };
                            _ = try gutter.print(&time_seg, .{});
                        }

                        var sender_segment = [_]vaxis.Segment{
                            .{
                                .text = sender,
                                .style = .{
                                    .fg = user.color,
                                    .bold = true,
                                },
                            },
                        };
                        sender_win = message_list_win.initChild(
                            6,
                            message_list_win.height -| h,
                            .expand,
                            .{ .limit = 1 },
                        );
                        _ = try sender_win.?.print(
                            &sender_segment,
                            .{ .wrap = .word },
                        );
                    }
                }
            }
        }

        const input_win = middle_win.initChild(0, win.height - 1, .expand, .{ .limit = 1 });
        input_win.clear();
        input.draw(input_win);

        try self.vx.render();
        self.state.buffers.count = row;
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
