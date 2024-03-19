const std = @import("std");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");
const ziglyph = vaxis.ziglyph;

const assert = std.debug.assert;
const base64 = std.base64.standard.Encoder;
const mem = std.mem;

const irc = @import("irc.zig");
const lua = @import("lua.zig");
const strings = @import("strings.zig");

// data structures
const Client = @import("Client.zig");
const Lua = @import("ziglua").Lua;
const Message = @import("Message.zig");

const log = std.log.scoped(.app);

const App = @This();

/// Any event our application will handle
pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    message: Message,
    connect: Client.Config,
    redraw,
};

pub const WriteRequest = struct {
    client: *Client,
    msg: []const u8,
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

selected_channel_index: usize = 0,
scroll_offset: usize = 0,
buffers: usize = 0,

/// initialize vaxis, lua state
pub fn init(alloc: std.mem.Allocator) !App {
    var app: App = .{
        .alloc = alloc,
        .clients = std.ArrayList(*Client).init(alloc),
        .lua = try Lua.init(&alloc),
        .vx = try vaxis.init(Event, .{}),
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
                        if (self.selected_channel_index >= self.buffers - 1)
                            self.selected_channel_index = 0
                        else
                            self.selected_channel_index +|= 1;
                    } else if (key.matches(vaxis.Key.up, .{ .alt = true })) {
                        if (self.selected_channel_index == 0)
                            self.selected_channel_index = self.buffers - 1
                        else
                            self.selected_channel_index -|= 1;
                    } else if (key.matches(vaxis.Key.enter, .{})) {
                        if (input.buf.items.len == 0) continue;

                        var i: usize = 0;
                        for (self.clients.items) |client| {
                            i += 1;
                            for (client.channels.items) |channel| {
                                defer i += 1;
                                if (i != self.selected_channel_index) continue;

                                var buf: [1024]u8 = undefined;
                                const content = try input.toOwnedSlice();
                                defer self.alloc.free(content);
                                const msg = try std.fmt.bufPrint(
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
                .mouse => |mouse| {
                    switch (mouse.button) {
                        .wheel_up => self.scroll_offset +|= 1,
                        .wheel_down => self.scroll_offset -|= 1,
                        else => {},
                    }
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
                                    log.err("required CAP not supported {s}", .{iter.next().?});
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
                        .RPL_WELCOME => {},
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
                            _ = iter.next() orelse continue :loop; // channel
                            _ = iter.next() orelse continue :loop; // username
                            _ = iter.next() orelse continue :loop; // host
                            _ = iter.next() orelse continue :loop; // server
                            const nick = iter.next() orelse continue :loop; // nick
                            const flags = iter.next() orelse continue :loop; // nick

                            const user_ptr = try msg.client.getOrCreateUser(nick);
                            if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                        },
                        .RPL_NAMREPLY => {
                            // syntax: <client> <symbol> <channel> :<nicks>
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue :loop; // client ("*")
                            _ = iter.next() orelse continue :loop; // symbol ("=", "@", "*")
                            const channel_name = iter.next() orelse continue :loop; // channel
                            const nick_list = iter.next() orelse continue :loop; // member list

                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            if (channel.inited) {
                                channel.members.clearAndFree();
                                channel.inited = false;
                            }
                            var nick_iter = std.mem.splitScalar(u8, nick_list, ' ');
                            while (nick_iter.next()) |nick| {
                                const user_ptr = try msg.client.getOrCreateUser(nick);
                                try channel.members.append(user_ptr);
                            }
                            try channel.sortMembers();
                        },
                        .RPL_ENDOFNAMES => {
                            // syntax: <client> <channel> :End of /NAMES list
                            var iter = msg.paramIterator();
                            _ = iter.next() orelse continue :loop; // client ("*")
                            const channel_name = iter.next() orelse continue :loop; // channel

                            var channel = try msg.client.getOrCreateChannel(channel_name);
                            channel.inited = true;
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
                        .PRIVMSG => {
                            keep_message = true;
                            // syntax: <target> :<message>
                            var iter = msg.paramIterator();
                            const target = iter.next() orelse continue;
                            assert(target.len > 0);
                            if (iter.next()) |content| {
                                if (std.mem.indexOf(u8, content, msg.client.config.nick)) |_| {
                                    try self.vx.notify("zirconium", content);
                                }
                            }
                            switch (target[0]) {
                                '#' => {
                                    var channel = try msg.client.getOrCreateChannel(target);
                                    try channel.messages.append(msg);
                                    channel.has_unread = true;
                                },
                                '$' => {}, // broadcast to all users
                                else => {}, // DM to me
                            }
                        },
                    }
                },
            }
        }

        const win = self.vx.window();
        win.clear();

        const channel_list_width = 16;
        const member_list_width = 16;
        const message_list_width = win.width - channel_list_width - member_list_width;

        // channel list
        var channel_list_win = win.initChild(
            0,
            0,
            .{ .limit = channel_list_width + 1 },
            .expand,
        );
        channel_list_win = vaxis.widgets.border.right(channel_list_win, .{});

        // member list
        const member_list_win = win.initChild(
            channel_list_width + message_list_width,
            0,
            .expand,
            .expand,
        );

        // message list
        var middle_win = win.initChild(
            channel_list_width + 1,
            0,
            .{ .limit = message_list_width - 1 },
            .expand,
        );
        middle_win = vaxis.widgets.border.right(middle_win, .{});

        var topic_win = middle_win.initChild(0, 0, .expand, .{ .limit = 2 });
        topic_win = vaxis.widgets.border.bottom(topic_win, .{});

        var row: usize = 0;
        for (self.clients.items) |client| {
            const style: vaxis.Style = if (row == self.selected_channel_index)
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
                const chan_style: vaxis.Style = if (row == self.selected_channel_index)
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
                        channel_list_width - 1,
                        row,
                        .{
                            .char = .{
                                .grapheme = "…",
                                .width = 1,
                            },
                        },
                    );
                if (row == self.selected_channel_index) {
                    channel.has_unread = false;
                    if (channel.messages.items.len == 0 and !channel.history_requested) {
                        var buf: [128]u8 = undefined;
                        const hist = try std.fmt.bufPrint(
                            &buf,
                            "CHATHISTORY LATEST {s} * 50\r\n",
                            .{channel.name},
                        );
                        channel.history_requested = true;
                        try self.queueWrite(client, hist);
                        const who = try std.fmt.bufPrint(
                            &buf,
                            "WHO {s}\r\n",
                            .{channel.name},
                        );
                        channel.history_requested = true;
                        try self.queueWrite(client, who);
                        const last_read = try std.fmt.bufPrint(
                            &buf,
                            "MARKREAD {s}\r\n",
                            .{channel.name},
                        );
                        try self.queueWrite(client, last_read);
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
                    var i: usize = channel.messages.items.len -| self.scroll_offset;
                    var h: usize = 0;
                    const message_list_win = middle_win.initChild(
                        0,
                        2,
                        .expand,
                        .{ .limit = middle_win.height -| 3 },
                    );
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

                        // print the content first
                        const content = iter.next() orelse continue;
                        if (content[0] == 0x01 and content[content.len - 1] == 0x01) {
                            // action message
                        }
                        const n = strings.lineCountForWindow(message_offset_win, content) + 1;
                        h += n;
                        var content_seg = [_]vaxis.Segment{
                            .{ .text = content },
                        };
                        const content_win = message_offset_win.initChild(
                            0,
                            message_offset_win.height -| h,
                            .expand,
                            .{ .limit = h },
                        );
                        _ = try content_win.print(
                            &content_seg,
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
                        const user = try client.getOrCreateUser(sender);

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
        self.buffers = row;
    }
}
