const std = @import("std");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const base64 = std.base64.standard.Encoder;
const mem = std.mem;

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
    // close vaxis
    {
        self.vx.stopReadThread();
        self.vx.deinit(self.alloc);
    }

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
    log.info("starting write thread", .{});
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

    loop: while (true) {
        const event = self.vx.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    return;
                }
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
        for (self.clients.items, 0..) |client, i| {
            var segs = [_]vaxis.Segment{
                .{ .text = client.config.name orelse client.config.server },
            };
            _ = try win.print(
                &segs,
                .{ .row_offset = i },
            );
        }
        try self.vx.render();
    }
}
