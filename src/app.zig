const std = @import("std");
const builtin = @import("builtin");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const zeit = @import("zeit");
const ziglua = @import("ziglua");
const Scrollbar = @import("Scrollbar.zig");
const main = @import("main.zig");
const format = @import("format.zig");

const irc = comlink.irc;
const lua = comlink.lua;
const mem = std.mem;
const vxfw = vaxis.vxfw;

const assert = std.debug.assert;

const Allocator = std.mem.Allocator;
const Base64Encoder = std.base64.standard.Encoder;
const Bind = comlink.Bind;
const Completer = comlink.Completer;
const Event = comlink.Event;
const Lua = ziglua.Lua;
const TextInput = vaxis.widgets.TextInput;
const WriteRequest = comlink.WriteRequest;

const log = std.log.scoped(.app);

const State = struct {
    buffers: struct {
        count: usize = 0,
        width: u16 = 16,
    } = .{},
    paste: struct {
        pasting: bool = false,
        has_newline: bool = false,

        fn showDialog(self: @This()) bool {
            return !self.pasting and self.has_newline;
        }
    } = .{},
};

pub const App = struct {
    config: comlink.Config,
    explicit_join: bool,
    alloc: std.mem.Allocator,
    /// System certificate bundle
    bundle: std.crypto.Certificate.Bundle,
    /// List of all configured clients
    clients: std.ArrayList(*irc.Client),
    /// if we have already called deinit
    deinited: bool,
    /// Process environment
    env: std.process.EnvMap,
    /// Local timezone
    tz: zeit.TimeZone,

    state: State,

    completer: ?Completer,

    binds: std.ArrayList(Bind),

    paste_buffer: std.ArrayList(u8),

    lua: *Lua,

    write_queue: comlink.WriteQueue,
    write_thread: std.Thread,

    view: vxfw.SplitView,
    buffer_list: vxfw.ListView,
    unicode: *const vaxis.Unicode,

    title_buf: [128]u8,

    // Only valid during an event handler
    ctx: ?*vxfw.EventContext,
    last_height: u16,

    /// Whether the application has focus or not
    has_focus: bool,

    fg: ?[3]u8,
    bg: ?[3]u8,
    yellow: ?[3]u8,

    const default_rhs: vxfw.Text = .{ .text = "TODO: update this text" };

    /// initialize vaxis, lua state
    pub fn init(self: *App, gpa: std.mem.Allocator, unicode: *const vaxis.Unicode) !void {
        self.* = .{
            .alloc = gpa,
            .config = .{},
            .state = .{},
            .clients = std.ArrayList(*irc.Client).init(gpa),
            .env = try std.process.getEnvMap(gpa),
            .binds = try std.ArrayList(Bind).initCapacity(gpa, 16),
            .paste_buffer = std.ArrayList(u8).init(gpa),
            .tz = try zeit.local(gpa, null),
            .lua = undefined,
            .write_queue = .{},
            .write_thread = undefined,
            .view = .{
                .width = self.state.buffers.width,
                .lhs = self.buffer_list.widget(),
                .rhs = default_rhs.widget(),
            },
            .explicit_join = false,
            .bundle = .{},
            .deinited = false,
            .completer = null,
            .buffer_list = .{
                .children = .{
                    .builder = .{
                        .userdata = self,
                        .buildFn = App.bufferBuilderFn,
                    },
                },
                .draw_cursor = false,
            },
            .unicode = unicode,
            .title_buf = undefined,
            .ctx = null,
            .last_height = 0,
            .has_focus = true,
            .fg = null,
            .bg = null,
            .yellow = null,
        };

        self.lua = try Lua.init(&self.alloc);
        self.write_thread = try std.Thread.spawn(.{}, writeLoop, .{ self.alloc, &self.write_queue });

        try lua.init(self);

        try self.binds.append(.{
            .key = .{ .codepoint = 'c', .mods = .{ .ctrl = true } },
            .command = .quit,
        });
        try self.binds.append(.{
            .key = .{ .codepoint = vaxis.Key.up, .mods = .{ .alt = true } },
            .command = .@"prev-channel",
        });
        try self.binds.append(.{
            .key = .{ .codepoint = vaxis.Key.down, .mods = .{ .alt = true } },
            .command = .@"next-channel",
        });
        try self.binds.append(.{
            .key = .{ .codepoint = 'l', .mods = .{ .ctrl = true } },
            .command = .redraw,
        });

        // Get our system tls certs
        try self.bundle.rescan(gpa);
    }

    /// close the application. This closes the TUI, disconnects clients, and cleans
    /// up all resources
    pub fn deinit(self: *App) void {
        if (self.deinited) return;
        self.deinited = true;
        // Push a join command to the write thread
        self.write_queue.push(.join);

        // clean up clients
        {
            // Loop first to close connections. This will help us close faster by getting the
            // threads exited
            for (self.clients.items) |client| {
                client.close();
            }
            for (self.clients.items) |client| {
                client.deinit();
                self.alloc.destroy(client);
            }
            self.clients.deinit();
        }

        self.bundle.deinit(self.alloc);

        if (self.completer) |*completer| completer.deinit();
        self.binds.deinit();
        self.paste_buffer.deinit();
        self.tz.deinit();

        // Join the write thread
        self.write_thread.join();
        self.env.deinit();
        self.lua.deinit();
    }

    pub fn widget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = App.typeErasedCaptureHandler,
            .eventHandler = App.typeErasedEventHandler,
            .drawFn = App.typeErasedDrawFn,
        };
    }

    fn typeErasedCaptureHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        // Rewrite the ctx pointer every frame. We don't actually need to do this with the current
        // vxfw runtime, because the context pointer is always valid. But for safe keeping, we will
        // do it this way.
        //
        // In general, this is bad practice. But we need to be able to access this from lua
        // callbacks
        self.ctx = ctx;
        switch (event) {
            .color_report => |color| {
                switch (color.kind) {
                    .fg => self.fg = color.value,
                    .bg => self.bg = color.value,
                    .index => |index| {
                        switch (index) {
                            3 => self.yellow = color.value,
                            else => {},
                        }
                    },
                    .cursor => {},
                }
                if (self.fg != null and self.bg != null) {
                    for (self.clients.items) |client| {
                        for (client.channels.items) |channel| {
                            channel.text_field.style.bg = self.blendBg(10);
                        }
                    }
                }
            },
            .key_press => |key| {
                if (self.state.paste.pasting) {
                    ctx.consume_event = true;
                    // Always ignore enter key
                    if (key.codepoint == vaxis.Key.enter) return;
                    if (key.text) |text| {
                        try self.paste_buffer.appendSlice(text);
                    }
                    return;
                }
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
                for (self.binds.items) |bind| {
                    if (key.matches(bind.key.codepoint, bind.key.mods)) {
                        switch (bind.command) {
                            .quit => ctx.quit = true,
                            .@"next-channel" => self.nextChannel(),
                            .@"prev-channel" => self.prevChannel(),
                            .redraw => try ctx.queueRefresh(),
                            .lua_function => |ref| try lua.execFn(self.lua, ref),
                            else => {},
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
            },
            .paste_start => self.state.paste.pasting = true,
            .paste_end => {
                self.state.paste.pasting = false;
                if (std.mem.indexOfScalar(u8, self.paste_buffer.items, '\n')) |_| {
                    log.debug("paste had line ending", .{});
                    return;
                }
                defer self.paste_buffer.clearRetainingCapacity();
                if (self.selectedBuffer()) |buffer| {
                    switch (buffer) {
                        .client => {},
                        .channel => |channel| {
                            try channel.text_field.insertSliceAtCursor(self.paste_buffer.items);
                            return ctx.consumeAndRedraw();
                        },
                    }
                }
            },
            .focus_out => self.has_focus = false,

            .focus_in => {
                self.has_focus = true;
                ctx.redraw = true;
            },

            else => {},
        }
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *App = @ptrCast(@alignCast(ptr));
        self.ctx = ctx;
        switch (event) {
            .init => {
                const title = try std.fmt.bufPrint(&self.title_buf, "comlink", .{});
                try ctx.setTitle(title);
                try ctx.tick(8, self.widget());
                try ctx.queryColor(.fg);
                try ctx.queryColor(.bg);
                try ctx.queryColor(.{ .index = 3 });
            },
            .tick => {
                for (self.clients.items) |client| {
                    if (client.status.load(.unordered) == .disconnected and
                        client.retry_delay_s == 0)
                    {
                        ctx.redraw = true;
                        try irc.Client.retryTickHandler(client, ctx, .tick);
                    }
                    client.drainFifo(ctx);
                    client.checkTypingStatus(ctx);
                }
                try ctx.tick(8, self.widget());
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *App = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();
        self.last_height = max.height;
        if (self.selectedBuffer()) |buffer| {
            switch (buffer) {
                .client => |client| self.view.rhs = client.view(),
                .channel => |channel| self.view.rhs = channel.view.widget(),
            }
        } else self.view.rhs = default_rhs.widget();

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // UI is a tree of splits
        // │         │                  │         │
        // │         │                  │         │
        // │ buffers │  buffer content  │ members │
        // │         │                  │         │
        // │         │                  │         │
        // │         │                  │         │
        // │         │                  │         │

        const sub: vxfw.SubSurface = .{
            .origin = .{ .col = 0, .row = 0 },
            .surface = try self.view.widget().draw(ctx),
        };
        try children.append(sub);

        return .{
            .size = ctx.max.size(),
            .widget = self.widget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn bufferBuilderFn(ptr: *const anyopaque, idx: usize, cursor: usize) ?vxfw.Widget {
        const self: *const App = @ptrCast(@alignCast(ptr));
        var i: usize = 0;
        for (self.clients.items) |client| {
            if (i == idx) return client.nameWidget(i == cursor);
            i += 1;
            for (client.channels.items) |channel| {
                if (i == idx) return channel.nameWidget(i == cursor);
                i += 1;
            }
        }
        return null;
    }

    pub fn connect(self: *App, cfg: irc.Client.Config) !void {
        const client = try self.alloc.create(irc.Client);
        client.* = try irc.Client.init(self.alloc, self, &self.write_queue, cfg);
        try self.clients.append(client);
    }

    pub fn nextChannel(self: *App) void {
        if (self.ctx) |ctx| {
            self.buffer_list.nextItem(ctx);
            if (self.selectedBuffer()) |buffer| {
                switch (buffer) {
                    .client => {
                        ctx.requestFocus(self.widget()) catch {};
                    },
                    .channel => |channel| {
                        ctx.requestFocus(channel.text_field.widget()) catch {};
                    },
                }
            }
        }
    }

    pub fn prevChannel(self: *App) void {
        if (self.ctx) |ctx| {
            self.buffer_list.prevItem(ctx);
            if (self.selectedBuffer()) |buffer| {
                switch (buffer) {
                    .client => {
                        ctx.requestFocus(self.widget()) catch {};
                    },
                    .channel => |channel| {
                        ctx.requestFocus(channel.text_field.widget()) catch {};
                    },
                }
            }
        }
    }

    pub fn selectChannelName(self: *App, cl: *irc.Client, name: []const u8) void {
        var i: usize = 0;
        for (self.clients.items) |client| {
            i += 1;
            for (client.channels.items) |channel| {
                if (cl == client) {
                    if (std.mem.eql(u8, name, channel.name)) {
                        self.selectBuffer(.{ .channel = channel });
                    }
                }
                i += 1;
            }
        }
    }

    /// Blend fg and bg, otherwise return index 8. amt will be clamped to [0,100]. amt will be
    /// interpreted as percentage of fg to blend into bg
    pub fn blendBg(self: *App, amt: u8) vaxis.Color {
        const bg = self.bg orelse return .{ .index = 8 };
        const fg = self.fg orelse return .{ .index = 8 };
        // Clamp to (0,100)
        if (amt == 0) return .{ .rgb = bg };
        if (amt >= 100) return .{ .rgb = fg };

        const fg_r: u16 = std.math.mulWide(u8, fg[0], amt);
        const fg_g: u16 = std.math.mulWide(u8, fg[1], amt);
        const fg_b: u16 = std.math.mulWide(u8, fg[2], amt);

        const bg_multiplier: u8 = 100 - amt;
        const bg_r: u16 = std.math.mulWide(u8, bg[0], bg_multiplier);
        const bg_g: u16 = std.math.mulWide(u8, bg[1], bg_multiplier);
        const bg_b: u16 = std.math.mulWide(u8, bg[2], bg_multiplier);

        return .{
            .rgb = .{
                @intCast((fg_r + bg_r) / 100),
                @intCast((fg_g + bg_g) / 100),
                @intCast((fg_b + bg_b) / 100),
            },
        };
    }

    /// Blend fg and bg, otherwise return index 8. amt will be clamped to [0,100]. amt will be
    /// interpreted as percentage of fg to blend into bg
    pub fn blendYellow(self: *App, amt: u8) vaxis.Color {
        const bg = self.bg orelse return .{ .index = 3 };
        const yellow = self.yellow orelse return .{ .index = 3 };
        // Clamp to (0,100)
        if (amt == 0) return .{ .rgb = bg };
        if (amt >= 100) return .{ .rgb = yellow };

        const yellow_r: u16 = std.math.mulWide(u8, yellow[0], amt);
        const yellow_g: u16 = std.math.mulWide(u8, yellow[1], amt);
        const yellow_b: u16 = std.math.mulWide(u8, yellow[2], amt);

        const bg_multiplier: u8 = 100 - amt;
        const bg_r: u16 = std.math.mulWide(u8, bg[0], bg_multiplier);
        const bg_g: u16 = std.math.mulWide(u8, bg[1], bg_multiplier);
        const bg_b: u16 = std.math.mulWide(u8, bg[2], bg_multiplier);

        return .{
            .rgb = .{
                @intCast((yellow_r + bg_r) / 100),
                @intCast((yellow_g + bg_g) / 100),
                @intCast((yellow_b + bg_b) / 100),
            },
        };
    }

    /// handle a command
    pub fn handleCommand(self: *App, buffer: irc.Buffer, cmd: []const u8) !void {
        const lua_state = self.lua;
        const command: comlink.Command = blk: {
            const start: u1 = if (cmd[0] == '/') 1 else 0;
            const end = mem.indexOfScalar(u8, cmd, ' ') orelse cmd.len;
            if (comlink.Command.fromString(cmd[start..end])) |internal|
                break :blk internal;
            if (comlink.Command.user_commands.get(cmd[start..end])) |ref| {
                const str = if (end == cmd.len) "" else std.mem.trim(u8, cmd[end..], " ");
                return lua.execUserCommand(lua_state, str, ref);
            }
            return error.UnknownCommand;
        };
        var buf: [1024]u8 = undefined;
        const client: *irc.Client = switch (buffer) {
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
                return client.queueWrite(msg);
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
                // Ensure buffer exists
                self.explicit_join = true;
                return client.queueWrite(msg);
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
                return client.queueWrite(msg);
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
                return client.queueWrite(msg);
            },
            .query => {
                const s = std.mem.indexOfScalar(u8, cmd, ' ') orelse return error.InvalidCommand;
                const e = std.mem.indexOfScalarPos(u8, cmd, s + 1, ' ') orelse cmd.len;
                if (cmd[s + 1] == '#') return error.InvalidCommand;

                const ch = try client.getOrCreateChannel(cmd[s + 1 .. e]);
                try client.requestHistory(.after, ch);
                self.selectChannelName(client, ch.name);
                //handle sending the message
                if (cmd.len - e > 1) {
                    const msg = try std.fmt.bufPrint(
                        &buf,
                        "PRIVMSG {s} :{s}\r\n",
                        .{
                            cmd[s + 1 .. e],
                            cmd[e + 1 ..],
                        },
                    );
                    return client.queueWrite(msg);
                }
            },
            .names => {
                if (channel == null) return error.InvalidCommand;
                const msg = try std.fmt.bufPrint(&buf, "NAMES {s}\r\n", .{channel.?.name});
                return client.queueWrite(msg);
            },
            .@"next-channel" => self.nextChannel(),
            .@"prev-channel" => self.prevChannel(),
            .quit => {
                if (self.ctx) |ctx| ctx.quit = true;
            },
            .who => {
                if (channel == null) return error.InvalidCommand;
                const msg = try std.fmt.bufPrint(
                    &buf,
                    "WHO {s}\r\n",
                    .{
                        channel.?.name,
                    },
                );
                return client.queueWrite(msg);
            },
            .part, .close => {
                if (channel == null) return error.InvalidCommand;
                var it = std.mem.tokenizeScalar(u8, cmd, ' ');

                // Skip command
                _ = it.next();
                const target = it.next() orelse channel.?.name;

                if (target[0] != '#') {
                    for (client.channels.items, 0..) |search, i| {
                        if (!mem.eql(u8, search.name, target)) continue;
                        client.app.prevChannel();
                        var chan = client.channels.orderedRemove(i);
                        chan.deinit(self.alloc);
                        self.alloc.destroy(chan);
                        break;
                    }
                } else {
                    const msg = try std.fmt.bufPrint(
                        &buf,
                        "PART {s}\r\n",
                        .{
                            target,
                        },
                    );
                    return client.queueWrite(msg);
                }
            },
            .redraw => {},
            // .redraw => self.vx.queueRefresh(),
            .version => {
                if (channel == null) return error.InvalidCommand;
                const msg = try std.fmt.bufPrint(
                    &buf,
                    "NOTICE {s} :\x01VERSION comlink {s}\x01\r\n",
                    .{
                        channel.?.name,
                        main.version,
                    },
                );
                return client.queueWrite(msg);
            },
            .lua_function => {}, // we don't handle these from the text-input
        }
    }

    pub fn selectedBuffer(self: *App) ?irc.Buffer {
        var i: usize = 0;
        for (self.clients.items) |client| {
            if (i == self.buffer_list.cursor) return .{ .client = client };
            i += 1;
            for (client.channels.items) |channel| {
                if (i == self.buffer_list.cursor) return .{ .channel = channel };
                i += 1;
            }
        }
        return null;
    }

    pub fn selectBuffer(self: *App, buffer: irc.Buffer) void {
        var i: u32 = 0;
        switch (buffer) {
            .client => |target| {
                for (self.clients.items) |client| {
                    if (client == target) {
                        if (self.ctx) |ctx| {
                            ctx.requestFocus(self.widget()) catch {};
                        }
                        self.buffer_list.cursor = i;
                        self.buffer_list.ensureScroll();
                        return;
                    }
                    i += 1;
                    for (client.channels.items) |_| i += 1;
                }
            },
            .channel => |target| {
                for (self.clients.items) |client| {
                    i += 1;
                    for (client.channels.items) |channel| {
                        if (channel == target) {
                            self.buffer_list.cursor = i;
                            self.buffer_list.ensureScroll();
                            channel.doSelect();
                            if (self.ctx) |ctx| {
                                ctx.requestFocus(channel.text_field.widget()) catch {};
                            }
                            return;
                        }
                        i += 1;
                    }
                }
            },
        }
    }
};

/// this loop is run in a separate thread and handles writes to all clients.
/// Message content is deallocated when the write request is completed
fn writeLoop(alloc: std.mem.Allocator, queue: *comlink.WriteQueue) !void {
    log.debug("starting write thread", .{});
    while (true) {
        const req = queue.pop();
        switch (req) {
            .write => |w| {
                try w.client.write(w.msg);
                alloc.free(w.msg);
            },
            .join => {
                while (queue.tryPop()) |r| {
                    switch (r) {
                        .write => |w| alloc.free(w.msg),
                        else => {},
                    }
                }
                return;
            },
        }
    }
}
