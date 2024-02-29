const std = @import("std");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const assert = std.debug.assert;
const base64 = std.base64.standard.Encoder;
const mem = std.mem;

const irc = @import("irc.zig");
const lua = @import("lua.zig");

// data structures
const Client = @import("Client.zig");
const Lua = @import("ziglua").Lua;
const Message = @import("Message.zig");

const log = std.log.scoped(.app);

const App = @This();

/// Any event our application will handle
pub const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    message: Message,
    connect: Client.Config,
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
        const event = self.vx.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    return;
                }
                try input.update(.{ .key_press = key });
            },
            .winsize => |ws| try self.vx.resize(self.alloc, ws),
            .connect => |cfg| {
                var client = try self.alloc.create(Client);
                client.* = try Client.init(self.alloc, self, cfg);
                const client_read_thread = try std.Thread.spawn(.{}, Client.readLoop, .{client});
                client_read_thread.detach();
                try client.connect();
                try self.clients.append(client);
            },
            .message => |msg| {
                defer msg.deinit(self.alloc);
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
                    .RPL_SASLSUCCESS => {},
                    .RPL_NAMREPLY => {
                        // syntax: <client> <symbol> <channel> :<nicks>
                        var iter = msg.paramIterator();
                        _ = iter.next() orelse continue :loop; // client ("*")
                        _ = iter.next() orelse continue :loop; // symbol ("=", "@", "*")
                        const channel_name = iter.next() orelse continue :loop; // channel

                        for (msg.client.channels.items, 0..) |chan, i| {
                            if (mem.eql(u8, chan.name, channel_name)) {
                                var channel = msg.client.channels.swapRemove(i);
                                channel.deinit(self.alloc);
                                break;
                            }
                        }
                        var channel: irc.Channel = .{
                            .name = try self.alloc.dupe(u8, channel_name),
                            .members = std.ArrayList(*irc.User).init(self.alloc),
                        };

                        const nick_list = iter.next() orelse continue :loop; // member list
                        var nick_iter = std.mem.splitScalar(u8, nick_list, ' ');
                        var users = &msg.client.users;
                        var members = &channel.members;
                        while (nick_iter.next()) |nick| {
                            const user_ptr: *irc.User = users.getPtr(nick) orelse blk: {
                                const user: irc.User = .{
                                    .nick = try self.alloc.dupe(u8, nick),
                                };
                                try users.put(user.nick, user);

                                break :blk users.getPtr(nick) orelse unreachable;
                            };
                            try members.append(user_ptr);
                        }
                        try msg.client.channels.append(channel);

                        std.sort.insertion(irc.Channel, msg.client.channels.items, {}, irc.Channel.compare);
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
                }
            },
        }

        const win = self.vx.window();
        win.clear();
        var row: usize = 0;

        const channel_list_width = 16;
        const member_list_width = 16;
        const message_list_width = win.width - channel_list_width - member_list_width;

        // draw the channel list (left sidebar)
        var channel_list_win = win.initChild(
            0,
            0,
            .{ .limit = channel_list_width + 1 },
            .expand,
        );
        channel_list_win = vaxis.widgets.border.right(channel_list_win, .{});
        for (self.clients.items) |client| {
            var segs = [_]vaxis.Segment{
                .{ .text = client.config.name orelse client.config.server },
            };
            _ = try channel_list_win.print(
                &segs,
                .{ .row_offset = row },
            );
            row += 1;

            for (client.channels.items) |channel| {
                defer row += 1;
                var chan_seg = [_]vaxis.Segment{
                    .{ .text = "  " },
                    .{ .text = channel.name },
                };
                const overflow = try channel_list_win.print(
                    &chan_seg,
                    .{
                        .row_offset = row,
                        .wrap = .none,
                    },
                );
                if (overflow)
                    channel_list_win.writeCell(channel_list_width - 1, row, .{
                        .char = .{
                            .grapheme = "…",
                            .width = 1,
                        },
                    });
            }
        }

        // draw the member list (right sidebar)
        const member_list_win = win.initChild(channel_list_width + message_list_width, 0, .expand, .expand);
        member_list_win.fill(.{
            .style = .{
                .bg = .{ .index = 2 },
            },
        });

        // draw the message list
        var message_list_win = win.initChild(channel_list_width + 1, 0, .{ .limit = message_list_width - 1 }, .expand);
        message_list_win = vaxis.widgets.border.right(message_list_win, .{});
        message_list_win.fill(.{
            .style = .{
                .bg = .{ .index = 1 },
            },
        });

        var topic_win = message_list_win.initChild(0, 0, .expand, .{ .limit = 1 });
        topic_win.fill(.{
            .style = .{
                .bg = .{ .index = 4 },
            },
        });
        var input_win = message_list_win.initChild(0, win.height - 1, .expand, .{ .limit = 1 });
        input_win.fill(.{
            .style = .{
                .bg = .{ .index = 3 },
            },
        });
        input.draw(input_win);

        try self.vx.render();
    }
}
