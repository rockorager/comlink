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

    should_quit: bool,

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

    const default_rhs: vxfw.Text = .{ .text = "TODO: update this text" };

    /// initialize vaxis, lua state
    pub fn init(self: *App, gpa: std.mem.Allocator, unicode: *const vaxis.Unicode) !void {
        self.* = .{
            .alloc = gpa,
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
            .should_quit = false,
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
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
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
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                }
                for (self.binds.items) |bind| {
                    if (key.matches(bind.key.codepoint, bind.key.mods)) {
                        switch (bind.command) {
                            .quit => self.should_quit = true,
                            .@"next-channel" => self.nextChannel(),
                            .@"prev-channel" => self.prevChannel(),
                            // .redraw => self.vx.queueRefresh(),
                            .lua_function => |ref| try lua.execFn(self.lua, ref),
                            else => {},
                        }
                        return ctx.consumeAndRedraw();
                    }
                }
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

    fn contentWidget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = null,
            .eventHandler = null,
            .drawFn = App.typeErasedContentDrawFn,
        };
    }

    fn typeErasedContentDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        _ = ptr;
        const text: vxfw.Text = .{ .text = "content" };
        return text.draw(ctx);
    }

    fn memberWidget(self: *App) vxfw.Widget {
        return .{
            .userdata = self,
            .captureHandler = null,
            .eventHandler = null,
            .drawFn = App.typeErasedMembersDrawFn,
        };
    }

    fn typeErasedMembersDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        _ = ptr;
        const text: vxfw.Text = .{ .text = "members" };
        return text.draw(ctx);
    }

    pub fn connect(self: *App, cfg: irc.Client.Config) !void {
        const client = try self.alloc.create(irc.Client);
        client.* = try irc.Client.init(self.alloc, self, &self.write_queue, cfg);
        try self.clients.append(client);
    }

    pub fn nextChannel(self: *App) void {
        // When leaving a channel we mark it as read, so we make sure that's done
        // before we change to the new channel.
        self.markSelectedChannelRead();
        if (self.ctx) |ctx| {
            self.buffer_list.nextItem(ctx);
        }
    }

    pub fn prevChannel(self: *App) void {
        // When leaving a channel we mark it as read, so we make sure that's done
        // before we change to the new channel.
        self.markSelectedChannelRead();
        if (self.ctx) |ctx| {
            self.buffer_list.prevItem(ctx);
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
                        var chan = client.channels.orderedRemove(i);
                        self.buffer_list.cursor -|= 1;
                        self.buffer_list.ensureScroll();
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
        self.markSelectedChannelRead();
        var i: u32 = 0;
        switch (buffer) {
            .client => |target| {
                for (self.clients.items) |client| {
                    if (client == target) {
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
                            if (target.messageViewIsAtBottom()) target.has_unread = false;
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

    fn draw(self: *App, input: *TextInput) !void {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const allocator = arena.allocator();

        // reset window state
        const win = self.vx.window();
        win.clear();
        self.vx.setMouseShape(.default);

        // Handle resize of sidebars
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

        // Define the layout
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

        const message_list_win = middle_win.child(.{
            .y_off = 2,
            .height = .{ .limit = middle_win.height -| 4 },
            .width = .{ .limit = middle_win.width -| 1 },
        });

        // Draw the buffer list
        try self.drawBufferList(self.clients.items, channel_list_win);

        // Get our currently selected buffer and draw it
        const buffer = self.selectedBuffer() orelse return;
        switch (buffer) {
            .client => {}, // nothing to do

            .channel => |channel| {
                // Request WHO if we don't already have it
                if (!channel.who_requested) try channel.client.whox(channel);

                // Set the title of the terminal
                {
                    var buf: [64]u8 = undefined;
                    const title = std.fmt.bufPrint(&buf, "{s} - comlink", .{channel.name}) catch title: {
                        // If the channel name is too long to fit in our buffer just truncate
                        const len = @min(buf.len, channel.name.len);
                        @memcpy(buf[0..len], channel.name[0..len]);
                        break :title buf[0..len];
                    };
                    try self.vx.setTitle(self.tty.anyWriter(), title);
                }

                // Draw the topic
                try self.drawTopic(topic_win, channel.topic orelse "");

                // Draw the member list
                try self.drawMemberList(member_list_win, channel);

                // Draw the message list
                try self.drawMessageList(allocator, message_list_win, channel);

                // draw a scrollbar
                {
                    const scrollbar: Scrollbar = .{
                        .total = channel.messages.items.len,
                        .view_size = message_list_win.height / 3, // ~3 lines per message
                        .bottom = self.state.messages.scroll_offset,
                    };
                    const scrollbar_win = middle_win.child(.{
                        .x_off = message_list_win.width,
                        .y_off = 2,
                        .height = .{ .limit = middle_win.height -| 4 },
                    });
                    scrollbar.draw(scrollbar_win);
                }

                // draw the completion list
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
            },
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
        const msg_len = input.buf.realLength();
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
        input.draw(input_win);

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
            // const button: Button = .{
            //     .label = "Accept",
            //     .style = .{ .bg = .{ .index = 7 } },
            // };
            // try button.draw(bordered.child(.{
            //     .x_off = 3,
            //     .y_off = bordered.height - 4,
            //     .height = .{ .limit = 3 },
            //     .width = .{ .limit = 10 },
            // }));
        }

        var buffered = self.tty.bufferedWriter();
        try self.vx.render(buffered.writer().any());
        try buffered.flush();
    }

    fn drawMessageList(
        self: *App,
        arena: std.mem.Allocator,
        win: vaxis.Window,
        channel: *irc.Channel,
    ) !void {
        if (channel.messages.items.len == 0) return;
        const client = channel.client;
        const last_msg_idx = channel.messages.items.len -| self.state.messages.scroll_offset;
        const messages = channel.messages.items[0..@max(1, last_msg_idx)];
        // We draw a gutter for time information
        const gutter_width: usize = 6;

        // Our message list is offset by the gutter width
        const message_offset_win = win.child(.{ .x_off = gutter_width });

        // Handle mouse
        if (win.hasMouse(self.state.mouse)) |mouse| {
            switch (mouse.button) {
                .wheel_up => {
                    self.state.messages.scroll_offset +|= 1;
                    self.state.mouse.?.button = .none;
                    self.state.messages.pending_scroll += 2;
                },
                .wheel_down => {
                    self.state.messages.scroll_offset -|= 1;
                    self.state.mouse.?.button = .none;
                    self.state.messages.pending_scroll -= 2;
                },
                else => {},
            }
        }
        self.state.messages.scroll_offset = @min(
            self.state.messages.scroll_offset,
            channel.messages.items.len -| 1,
        );

        // Define a few state variables for the loop
        const last_msg = messages[messages.len -| 1];

        // Initialize prev_time to the time of the last message, falling back to "now"
        var prev_time: zeit.Instant = last_msg.localTime(&self.tz) orelse
            try zeit.instant(.{ .source = .now, .timezone = &self.tz });

        // Initialize prev_sender to the sender of the last message
        var prev_sender: []const u8 = if (last_msg.source()) |src| blk: {
            if (std.mem.indexOfScalar(u8, src, '!')) |idx|
                break :blk src[0..idx];
            if (std.mem.indexOfScalar(u8, src, '@')) |idx|
                break :blk src[0..idx];
            break :blk src;
        } else "";

        // y_off is the row we are printing on
        var y_off: usize = win.height;

        // Formatted message segments
        var segments = std.ArrayList(vaxis.Segment).init(arena);

        var msg_iter = std.mem.reverseIterator(messages);
        var i: usize = messages.len;
        while (msg_iter.next()) |message| {
            i -|= 1;
            segments.clearRetainingCapacity();

            // Get the sender nick
            const sender: []const u8 = if (message.source()) |src| blk: {
                if (std.mem.indexOfScalar(u8, src, '!')) |idx|
                    break :blk src[0..idx];
                if (std.mem.indexOfScalar(u8, src, '@')) |idx|
                    break :blk src[0..idx];
                break :blk src;
            } else "";

            // Save sender state after this loop
            defer prev_sender = sender;

            // Before we print the message, we need to decide if we should print the sender name of
            // the previous message. There are two cases we do this:
            // 1. The previous message was sent by someone other than the current message
            // 2. A certain amount of time has elapsed between messages
            //
            // Each case requires that we have space in the window to print the sender (y_off > 0)
            const time_gap = if (message.localTime(&self.tz)) |time| blk: {
                // Save message state for next loop
                defer prev_time = time;
                // time_gap is true when the difference between this message and last message is
                // greater than 5 minutes
                break :blk (prev_time.timestamp_ns -| time.timestamp_ns) > (5 * std.time.ns_per_min);
            } else false;

            // Print the sender of the previous message
            if (y_off > 0 and (time_gap or !std.mem.eql(u8, prev_sender, sender))) {
                // Go up one line
                y_off -|= 1;

                // Get the user so we have the correct color
                const user = try client.getOrCreateUser(prev_sender);
                const sender_win = message_offset_win.child(.{
                    .y_off = y_off,
                    .height = .{ .limit = 1 },
                });

                // We will use the result to see if our mouse is hovering over the nickname
                const sender_result = try sender_win.printSegment(
                    .{
                        .text = prev_sender,
                        .style = .{ .fg = user.color, .bold = true },
                    },
                    .{ .wrap = .none },
                );

                // If our mouse is over the nickname, we set it to a pointer
                const result_win = sender_win.child(.{ .width = .{ .limit = sender_result.col } });
                if (result_win.hasMouse(self.state.mouse)) |_| {
                    self.vx.setMouseShape(.pointer);
                    // If we have a realname we print it
                    if (user.real_name) |real_name| {
                        _ = try sender_win.printSegment(
                            .{
                                .text = real_name,
                                .style = .{ .italic = true, .dim = true },
                            },
                            .{
                                .wrap = .none,
                                .col_offset = sender_result.col + 1,
                            },
                        );
                    }
                }

                // Go up one more line to print the next message
                y_off -|= 1;
            }

            // We are out of space
            if (y_off == 0) break;

            const user = try client.getOrCreateUser(sender);
            try format.message(&segments, user, message);

            // Get the line count for this message
            const content_height = lineCountForWindow(message_offset_win, segments.items);

            const content_win = message_offset_win.child(
                .{
                    .y_off = y_off -| content_height,
                    .height = .{ .limit = content_height },
                },
            );
            if (content_win.hasMouse(self.state.mouse)) |mouse| {
                var bg_idx: u8 = 8;
                if (mouse.type == .press and mouse.button == .middle) {
                    var list = std.ArrayList(u8).init(self.alloc);
                    defer list.deinit();
                    for (segments.items) |item| {
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
                for (segments.items) |*item| {
                    item.style.bg = .{ .index = bg_idx };
                }
            }
            var iter = message.paramIterator();
            // target is the channel, and we already handled that
            _ = iter.next() orelse continue;

            const content = iter.next() orelse continue;
            if (std.mem.indexOf(u8, content, client.nickname())) |_| {
                for (segments.items) |*item| {
                    if (item.style.fg == .default)
                        item.style.fg = .{ .index = 3 };
                }
            }

            // Color the background of unread messages gray.
            if (message.localTime(&self.tz)) |instant| {
                if (instant.unixTimestamp() > channel.last_read) {
                    for (segments.items) |*item| {
                        item.style.bg = .{ .index = 8 };
                    }
                }
            }

            _ = try content_win.print(
                segments.items,
                .{
                    .wrap = .word,
                },
            );
            if (content_height > y_off) break;
            const gutter = win.child(.{
                .y_off = y_off -| content_height,
                .width = .{ .limit = 6 },
            });

            if (message.localTime(&self.tz)) |instant| {
                var date: bool = false;
                const time = instant.time();
                var buf = try std.fmt.allocPrint(
                    arena,
                    "{d:0>2}:{d:0>2}",
                    .{ time.hour, time.minute },
                );
                if (i != 0 and channel.messages.items[i - 1].time() != null) {
                    const prev = channel.messages.items[i - 1].localTime(&self.tz).?.time();
                    if (time.day != prev.day) {
                        date = true;
                        buf = try std.fmt.allocPrint(
                            arena,
                            "{d:0>2}/{d:0>2}",
                            .{ @intFromEnum(time.month), time.day },
                        );
                    }
                }
                if (i == 0) {
                    date = true;
                    buf = try std.fmt.allocPrint(
                        arena,
                        "{d:0>2}/{d:0>2}",
                        .{ @intFromEnum(time.month), time.day },
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
                const sender_win = win.child(.{
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
                try client.requestHistory(.before, channel);
            }
        }
    }

    fn drawMemberList(self: *App, win: vaxis.Window, channel: *irc.Channel) !void {
        // Handle mouse
        {
            if (win.hasMouse(self.state.mouse)) |mouse| {
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

            self.state.members.scroll_offset = @min(
                self.state.members.scroll_offset,
                channel.members.items.len -| win.height,
            );
        }

        // Draw the list
        var member_row: usize = 0;
        for (channel.members.items) |*member| {
            defer member_row += 1;
            if (member_row < self.state.members.scroll_offset) continue;
            var member_seg = [_]vaxis.Segment{
                .{
                    .text = std.mem.asBytes(&member.prefix),
                },
                .{
                    .text = member.user.nick,
                    .style = .{
                        .fg = if (member.user.away)
                            .{ .index = 8 }
                        else
                            member.user.color,
                    },
                },
            };
            _ = try win.print(&member_seg, .{
                .row_offset = member_row -| self.state.members.scroll_offset,
            });
        }
    }

    fn drawTopic(_: *App, win: vaxis.Window, topic: []const u8) !void {
        _ = try win.printSegment(.{ .text = topic }, .{ .wrap = .none });
    }

    fn drawBufferList(self: *App, clients: []*irc.Client, win: vaxis.Window) !void {
        // Handle mouse
        {
            if (win.hasMouse(self.state.mouse)) |mouse| {
                switch (mouse.button) {
                    .wheel_up => {
                        self.state.buffers.scroll_offset -|= 3;
                        self.state.mouse.?.button = .none;
                    },
                    .wheel_down => {
                        self.state.buffers.scroll_offset +|= 3;
                        self.state.mouse.?.button = .none;
                    },
                    else => {},
                }
            }

            self.state.buffers.scroll_offset = @min(
                self.state.buffers.scroll_offset,
                self.state.buffers.count -| win.height,
            );
        }
        const buf_list_w = self.state.buffers.width;
        var row: usize = 0;

        defer self.state.buffers.count = row;
        for (clients) |client| {
            const scroll_offset = self.state.buffers.scroll_offset;
            if (!(row < scroll_offset)) {
                var style: vaxis.Style = if (row == self.state.buffers.selected_idx)
                    .{
                        .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                        .reverse = true,
                    }
                else
                    .{
                        .fg = if (client.status == .disconnected) .{ .index = 8 } else .default,
                    };
                const network_win = win.child(.{
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
            }
            row += 1;
            for (client.channels.items) |*channel| {
                defer row += 1;
                if (row < scroll_offset) continue;
                const channel_win = win.child(.{
                    .y_off = row -| scroll_offset,
                    .height = .{ .limit = 1 },
                });
                if (channel_win.hasMouse(self.state.mouse)) |mouse| {
                    if (mouse.type == .press and mouse.button == .left and self.state.buffers.selected_idx != row) {
                        // When leaving a channel we mark it as read, so we make sure that's done
                        // before we change to the new channel.
                        self.markSelectedChannelRead();
                        self.state.buffers.selected_idx = row;
                    }
                }

                const is_current = row == self.state.buffers.selected_idx;
                var chan_style: vaxis.Style = if (is_current)
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
                    win.writeCell(
                        buf_list_w -| 1,
                        row -| scroll_offset,
                        .{
                            .char = .{
                                .grapheme = "…",
                                .width = 1,
                            },
                            .style = chan_style,
                        },
                    );
            }
        }
    }

    pub fn markSelectedChannelRead(self: *App) void {
        const buffer = self.selectedBuffer() orelse return;

        switch (buffer) {
            .channel => |channel| {
                if (channel.messageViewIsAtBottom()) channel.markRead() catch return;
            },
            else => {},
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

/// Returns the number of lines the segments would consume in the given window
fn lineCountForWindow(win: vaxis.Window, segments: []const vaxis.Segment) usize {
    // Fastpath if we have fewer bytes than the width
    var byte_count: usize = 0;
    for (segments) |segment| {
        byte_count += segment.text.len;
    }
    // One line if we are fewer bytes than the width
    if (byte_count <= win.width) return 1;

    // Slow path. We have to layout the text
    const result = win.print(segments, .{ .commit = false, .wrap = .word }) catch return 0;
    if (result.col == 0)
        return result.row
    else
        return result.row + 1;
}
