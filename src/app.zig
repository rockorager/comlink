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
    mouse: ?vaxis.Mouse = null,
    members: struct {
        scroll_offset: usize = 0,
        width: u16 = 16,
        resizing: bool = false,
    } = .{},
    messages: struct {
        scroll_offset: usize = 0,
        pending_scroll: isize = 0,
    } = .{},
    buffers: struct {
        scroll_offset: usize = 0,
        count: usize = 0,
        selected_idx: usize = 0,
        width: u16 = 16,
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
        // const self: *App = @ptrCast(@alignCast(ptr));
        _ = ptr;
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
        if (self.selectedBuffer()) |buffer| {
            switch (buffer) {
                .client => |client| self.view.rhs = client.view(),
                .channel => |channel| self.view.rhs = channel.view.widget(),
            }
        } else self.view.rhs = default_rhs.widget();

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);
        _ = &children;

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

    // pub fn run(self: *App, lua_state: *Lua) !void {
    //     const writer = self.tty.anyWriter();
    //
    //     var loop: comlink.EventLoop = .{ .vaxis = &self.vx, .tty = &self.tty };
    //     try loop.init();
    //     try loop.start();
    //     defer loop.stop();
    //
    //     try self.vx.enterAltScreen(writer);
    //     try self.vx.queryTerminal(writer, 1 * std.time.ns_per_s);
    //     try self.vx.setMouseMode(writer, true);
    //     try self.vx.setBracketedPaste(writer, true);
    //
    //     // start our write thread
    //     var write_queue: comlink.WriteQueue = .{};
    //     const write_thread = try std.Thread.spawn(.{}, writeLoop, .{ self.alloc, &write_queue });
    //     defer {
    //         write_queue.push(.join);
    //         write_thread.join();
    //     }
    //
    //     // initialize lua state
    //     try lua.init(self, lua_state, &loop);
    //
    //     var input = TextInput.init(self.alloc, &self.vx.unicode);
    //     defer input.deinit();
    //
    //     var last_frame: i64 = std.time.milliTimestamp();
    //     loop: while (!self.should_quit) {
    //         var redraw: bool = false;
    //         std.time.sleep(8 * std.time.ns_per_ms);
    //         if (self.state.messages.pending_scroll != 0) {
    //             redraw = true;
    //             if (self.state.messages.pending_scroll > 0) {
    //                 self.state.messages.pending_scroll -= 1;
    //                 self.state.messages.scroll_offset += 1;
    //             } else {
    //                 self.state.messages.pending_scroll += 1;
    //                 self.state.messages.scroll_offset -|= 1;
    //             }
    //         }
    //         while (loop.tryEvent()) |event| {
    //             redraw = true;
    //             switch (event) {
    //                 .redraw => {},
    //                 .key_press => |key| {
    //                     if (self.state.paste.showDialog()) {
    //                         if (key.matches(vaxis.Key.escape, .{})) {
    //                             self.state.paste.has_newline = false;
    //                             self.paste_buffer.clearAndFree();
    //                         }
    //                         break;
    //                     }
    //                     if (self.state.paste.pasting) {
    //                         if (key.matches(vaxis.Key.enter, .{})) {
    //                             self.state.paste.has_newline = true;
    //                             try self.paste_buffer.append('\n');
    //                             continue :loop;
    //                         }
    //                         const text = key.text orelse continue :loop;
    //                         try self.paste_buffer.appendSlice(text);
    //                         continue;
    //                     }
    //                     for (self.binds.items) |bind| {
    //                         if (key.matches(bind.key.codepoint, bind.key.mods)) {
    //                             switch (bind.command) {
    //                                 .quit => self.should_quit = true,
    //                                 .@"next-channel" => self.nextChannel(),
    //                                 .@"prev-channel" => self.prevChannel(),
    //                                 .redraw => self.vx.queueRefresh(),
    //                                 .lua_function => |ref| try lua.execFn(lua_state, ref),
    //                                 else => {},
    //                             }
    //                             break;
    //                         }
    //                     } else if (key.matches(vaxis.Key.tab, .{})) {
    //                         // if we already have a completion word, then we are
    //                         // cycling through the options
    //                         if (self.completer) |*completer| {
    //                             const line = completer.next();
    //                             input.clearRetainingCapacity();
    //                             try input.insertSliceAtCursor(line);
    //                         } else {
    //                             var completion_buf: [irc.maximum_message_size]u8 = undefined;
    //                             const content = input.sliceToCursor(&completion_buf);
    //                             self.completer = try Completer.init(self.alloc, content);
    //                         }
    //                     } else if (key.matches(vaxis.Key.tab, .{ .shift = true })) {
    //                         if (self.completer) |*completer| {
    //                             const line = completer.prev();
    //                             input.clearRetainingCapacity();
    //                             try input.insertSliceAtCursor(line);
    //                         }
    //                     } else if (key.matches(vaxis.Key.enter, .{})) {
    //                         const buffer = self.selectedBuffer() orelse @panic("no buffer");
    //                         const content = try input.toOwnedSlice();
    //                         if (content.len == 0) continue;
    //                         defer self.alloc.free(content);
    //                         if (content[0] == '/')
    //                             self.handleCommand(lua_state, buffer, content) catch |err| {
    //                                 log.err("couldn't handle command: {}", .{err});
    //                             }
    //                         else {
    //                             switch (buffer) {
    //                                 .channel => |channel| {
    //                                     var buf: [1024]u8 = undefined;
    //                                     const msg = try std.fmt.bufPrint(
    //                                         &buf,
    //                                         "PRIVMSG {s} :{s}\r\n",
    //                                         .{
    //                                             channel.name,
    //                                             content,
    //                                         },
    //                                     );
    //                                     try channel.client.queueWrite(msg);
    //                                 },
    //                                 .client => log.err("can't send message to client", .{}),
    //                             }
    //                         }
    //                         if (self.completer != null) {
    //                             self.completer.?.deinit();
    //                             self.completer = null;
    //                         }
    //                     } else if (key.matches(vaxis.Key.page_up, .{})) {
    //                         self.state.messages.scroll_offset +|= 3;
    //                     } else if (key.matches(vaxis.Key.page_down, .{})) {
    //                         self.state.messages.scroll_offset -|= 3;
    //                     } else if (key.matches(vaxis.Key.home, .{})) {
    //                         self.state.messages.scroll_offset = 0;
    //                     } else {
    //                         if (self.completer != null and !key.isModifier()) {
    //                             self.completer.?.deinit();
    //                             self.completer = null;
    //                         }
    //                         log.debug("{}", .{key});
    //                         try input.update(.{ .key_press = key });
    //                     }
    //                 },
    //                 .paste_start => self.state.paste.pasting = true,
    //                 .paste_end => {
    //                     self.state.paste.pasting = false;
    //                     if (self.state.paste.has_newline) {
    //                         log.warn("NEWLINE", .{});
    //                     } else {
    //                         try input.insertSliceAtCursor(self.paste_buffer.items);
    //                         defer self.paste_buffer.clearAndFree();
    //                     }
    //                 },
    //                 .focus_out => self.state.mouse = null,
    //                 .mouse => |mouse| {
    //                     self.state.mouse = mouse;
    //                 },
    //                 .winsize => |ws| try self.vx.resize(self.alloc, writer, ws),
    //                 .connect => |cfg| {
    //                     const client = try self.alloc.create(irc.Client);
    //                     client.* = try irc.Client.init(self.alloc, self, &write_queue, cfg);
    //                     client.thread = try std.Thread.spawn(.{}, irc.Client.readLoop, .{ client, &loop });
    //                     try self.clients.append(client);
    //                 },
    //                 .irc => |irc_event| {
    //                     const msg: irc.Message = .{ .bytes = irc_event.msg.slice() };
    //                     const client = irc_event.client;
    //                     defer irc_event.msg.deinit();
    //                     switch (msg.command()) {
    //                         .unknown => {},
    //                         .CAP => {
    //                             // syntax: <client> <ACK/NACK> :caps
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue; // client
    //                             const ack_or_nak = iter.next() orelse continue;
    //                             const caps = iter.next() orelse continue;
    //                             var cap_iter = mem.splitScalar(u8, caps, ' ');
    //                             while (cap_iter.next()) |cap| {
    //                                 if (mem.eql(u8, ack_or_nak, "ACK")) {
    //                                     client.ack(cap);
    //                                     if (mem.eql(u8, cap, "sasl"))
    //                                         try client.queueWrite("AUTHENTICATE PLAIN\r\n");
    //                                 } else if (mem.eql(u8, ack_or_nak, "NAK")) {
    //                                     log.debug("CAP not supported {s}", .{cap});
    //                                 }
    //                             }
    //                         },
    //                         .AUTHENTICATE => {
    //                             var iter = msg.paramIterator();
    //                             while (iter.next()) |param| {
    //                                 // A '+' is the continuuation to send our
    //                                 // AUTHENTICATE info
    //                                 if (!mem.eql(u8, param, "+")) continue;
    //                                 var buf: [4096]u8 = undefined;
    //                                 const config = client.config;
    //                                 const sasl = try std.fmt.bufPrint(
    //                                     &buf,
    //                                     "{s}\x00{s}\x00{s}",
    //                                     .{ config.user, config.nick, config.password },
    //                                 );
    //
    //                                 // Create a buffer big enough for the base64 encoded string
    //                                 const b64_buf = try self.alloc.alloc(u8, Base64Encoder.calcSize(sasl.len));
    //                                 defer self.alloc.free(b64_buf);
    //                                 const encoded = Base64Encoder.encode(b64_buf, sasl);
    //                                 // Make our message
    //                                 const auth = try std.fmt.bufPrint(
    //                                     &buf,
    //                                     "AUTHENTICATE {s}\r\n",
    //                                     .{encoded},
    //                                 );
    //                                 try client.queueWrite(auth);
    //                                 if (config.network_id) |id| {
    //                                     const bind = try std.fmt.bufPrint(
    //                                         &buf,
    //                                         "BOUNCER BIND {s}\r\n",
    //                                         .{id},
    //                                     );
    //                                     try client.queueWrite(bind);
    //                                 }
    //                                 try client.queueWrite("CAP END\r\n");
    //                             }
    //                         },
    //                         .RPL_WELCOME => {
    //                             const now = try zeit.instant(.{});
    //                             var now_buf: [30]u8 = undefined;
    //                             const now_fmt = try now.time().bufPrint(&now_buf, .rfc3339);
    //
    //                             const past = try now.subtract(.{ .days = 7 });
    //                             var past_buf: [30]u8 = undefined;
    //                             const past_fmt = try past.time().bufPrint(&past_buf, .rfc3339);
    //
    //                             var buf: [128]u8 = undefined;
    //                             const targets = try std.fmt.bufPrint(
    //                                 &buf,
    //                                 "CHATHISTORY TARGETS timestamp={s} timestamp={s} 50\r\n",
    //                                 .{ now_fmt, past_fmt },
    //                             );
    //                             try client.queueWrite(targets);
    //                             // on_connect callback
    //                             try lua.onConnect(lua_state, client);
    //                         },
    //                         .RPL_YOURHOST => {},
    //                         .RPL_CREATED => {},
    //                         .RPL_MYINFO => {},
    //                         .RPL_ISUPPORT => {
    //                             // syntax: <client> <token>[ <token>] :are supported
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue; // client
    //                             while (iter.next()) |token| {
    //                                 if (mem.eql(u8, token, "WHOX"))
    //                                     client.supports.whox = true
    //                                 else if (mem.startsWith(u8, token, "PREFIX")) {
    //                                     const prefix = blk: {
    //                                         const idx = mem.indexOfScalar(u8, token, ')') orelse
    //                                             // default is "@+"
    //                                             break :blk try self.alloc.dupe(u8, "@+");
    //                                         break :blk try self.alloc.dupe(u8, token[idx + 1 ..]);
    //                                     };
    //                                     client.supports.prefix = prefix;
    //                                 }
    //                             }
    //                         },
    //                         .RPL_LOGGEDIN => {},
    //                         .RPL_TOPIC => {
    //                             // syntax: <client> <channel> :<topic>
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue :loop; // client ("*")
    //                             const channel_name = iter.next() orelse continue :loop; // channel
    //                             const topic = iter.next() orelse continue :loop; // topic
    //
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //                             if (channel.topic) |old_topic| {
    //                                 self.alloc.free(old_topic);
    //                             }
    //                             channel.topic = try self.alloc.dupe(u8, topic);
    //                         },
    //                         .RPL_SASLSUCCESS => {},
    //                         .RPL_WHOREPLY => {
    //                             // syntax: <client> <channel> <username> <host> <server> <nick> <flags> :<hopcount> <real name>
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue :loop; // client
    //                             const channel_name = iter.next() orelse continue :loop; // channel
    //                             if (mem.eql(u8, channel_name, "*")) continue;
    //                             _ = iter.next() orelse continue :loop; // username
    //                             _ = iter.next() orelse continue :loop; // host
    //                             _ = iter.next() orelse continue :loop; // server
    //                             const nick = iter.next() orelse continue :loop; // nick
    //                             const flags = iter.next() orelse continue :loop; // flags
    //
    //                             const user_ptr = try client.getOrCreateUser(nick);
    //                             if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //
    //                             const prefix = for (flags) |c| {
    //                                 if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
    //                                     break c;
    //                                 }
    //                             } else ' ';
    //
    //                             try channel.addMember(user_ptr, .{ .prefix = prefix });
    //                         },
    //                         .RPL_WHOSPCRPL => {
    //                             // syntax: <client> <channel> <nick> <flags> :<realname>
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue;
    //                             const channel_name = iter.next() orelse continue; // channel
    //                             const nick = iter.next() orelse continue;
    //                             const flags = iter.next() orelse continue;
    //
    //                             const user_ptr = try client.getOrCreateUser(nick);
    //                             if (iter.next()) |real_name| {
    //                                 if (user_ptr.real_name) |old_name| {
    //                                     self.alloc.free(old_name);
    //                                 }
    //                                 user_ptr.real_name = try self.alloc.dupe(u8, real_name);
    //                             }
    //                             if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //
    //                             const prefix = for (flags) |c| {
    //                                 if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
    //                                     break c;
    //                                 }
    //                             } else ' ';
    //
    //                             try channel.addMember(user_ptr, .{ .prefix = prefix });
    //                         },
    //                         .RPL_ENDOFWHO => {
    //                             // syntax: <client> <mask> :End of WHO list
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue :loop; // client
    //                             const channel_name = iter.next() orelse continue :loop; // channel
    //                             if (mem.eql(u8, channel_name, "*")) continue;
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //                             channel.in_flight.who = false;
    //                         },
    //                         .RPL_NAMREPLY => {
    //                             // syntax: <client> <symbol> <channel> :[<prefix>]<nick>{ [<prefix>]<nick>}
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue; // client
    //                             _ = iter.next() orelse continue; // symbol
    //                             const channel_name = iter.next() orelse continue; // channel
    //                             const names = iter.next() orelse continue;
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //                             var name_iter = std.mem.splitScalar(u8, names, ' ');
    //                             while (name_iter.next()) |name| {
    //                                 const nick, const prefix = for (client.supports.prefix) |ch| {
    //                                     if (name[0] == ch) {
    //                                         break .{ name[1..], name[0] };
    //                                     }
    //                                 } else .{ name, ' ' };
    //
    //                                 if (prefix != ' ') {
    //                                     log.debug("HAS PREFIX {s}", .{name});
    //                                 }
    //
    //                                 const user_ptr = try client.getOrCreateUser(nick);
    //
    //                                 try channel.addMember(user_ptr, .{ .prefix = prefix, .sort = false });
    //                             }
    //
    //                             channel.sortMembers();
    //                         },
    //                         .RPL_ENDOFNAMES => {
    //                             // syntax: <client> <channel> :End of /NAMES list
    //                             var iter = msg.paramIterator();
    //                             _ = iter.next() orelse continue; // client
    //                             const channel_name = iter.next() orelse continue; // channel
    //                             var channel = try client.getOrCreateChannel(channel_name);
    //                             channel.in_flight.names = false;
    //                         },
    //                         .BOUNCER => {
    //                             var iter = msg.paramIterator();
    //                             while (iter.next()) |param| {
    //                                 if (mem.eql(u8, param, "NETWORK")) {
    //                                     const id = iter.next() orelse continue;
    //                                     const attr = iter.next() orelse continue;
    //                                     // check if we already have this network
    //                                     for (self.clients.items, 0..) |cl, i| {
    //                                         if (cl.config.network_id) |net_id| {
    //                                             if (mem.eql(u8, net_id, id)) {
    //                                                 if (mem.eql(u8, attr, "*")) {
    //                                                     // * means the network was
    //                                                     // deleted
    //                                                     cl.deinit();
    //                                                     _ = self.clients.swapRemove(i);
    //                                                 }
    //                                                 continue :loop;
    //                                             }
    //                                         }
    //                                     }
    //
    //                                     var cfg = client.config;
    //                                     cfg.network_id = try self.alloc.dupe(u8, id);
    //
    //                                     var attr_iter = std.mem.splitScalar(u8, attr, ';');
    //                                     while (attr_iter.next()) |kv| {
    //                                         const n = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
    //                                         const key = kv[0..n];
    //                                         if (mem.eql(u8, key, "name"))
    //                                             cfg.name = try self.alloc.dupe(u8, kv[n + 1 ..])
    //                                         else if (mem.eql(u8, key, "nickname"))
    //                                             cfg.network_nick = try self.alloc.dupe(u8, kv[n + 1 ..]);
    //                                     }
    //                                     loop.postEvent(.{ .connect = cfg });
    //                                 }
    //                             }
    //                         },
    //                         .AWAY => {
    //                             const src = msg.source() orelse continue :loop;
    //                             var iter = msg.paramIterator();
    //                             const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
    //                             const user = try client.getOrCreateUser(src[0..n]);
    //                             // If there are any params, the user is away. Otherwise
    //                             // they are back.
    //                             user.away = if (iter.next()) |_| true else false;
    //                         },
    //                         .BATCH => {
    //                             var iter = msg.paramIterator();
    //                             const tag = iter.next() orelse continue;
    //                             switch (tag[0]) {
    //                                 '+' => {
    //                                     const batch_type = iter.next() orelse continue;
    //                                     if (mem.eql(u8, batch_type, "chathistory")) {
    //                                         const target = iter.next() orelse continue;
    //                                         var channel = try client.getOrCreateChannel(target);
    //                                         channel.at_oldest = true;
    //                                         const duped_tag = try self.alloc.dupe(u8, tag[1..]);
    //                                         try client.batches.put(duped_tag, channel);
    //                                     }
    //                                 },
    //                                 '-' => {
    //                                     const key = client.batches.getKey(tag[1..]) orelse continue;
    //                                     var chan = client.batches.get(key) orelse @panic("key should exist here");
    //                                     chan.history_requested = false;
    //                                     _ = client.batches.remove(key);
    //                                     self.alloc.free(key);
    //                                 },
    //                                 else => {},
    //                             }
    //                         },
    //                         .CHATHISTORY => {
    //                             var iter = msg.paramIterator();
    //                             const should_targets = iter.next() orelse continue;
    //                             if (!mem.eql(u8, should_targets, "TARGETS")) continue;
    //                             const target = iter.next() orelse continue;
    //                             // we only add direct messages, not more channels
    //                             assert(target.len > 0);
    //                             if (target[0] == '#') continue;
    //
    //                             var channel = try client.getOrCreateChannel(target);
    //                             const user_ptr = try client.getOrCreateUser(target);
    //                             const me_ptr = try client.getOrCreateUser(client.nickname());
    //                             try channel.addMember(user_ptr, .{});
    //                             try channel.addMember(me_ptr, .{});
    //                             // we set who_requested so we don't try to request
    //                             // who on DMs
    //                             channel.who_requested = true;
    //                             var buf: [128]u8 = undefined;
    //                             const mark_read = try std.fmt.bufPrint(
    //                                 &buf,
    //                                 "MARKREAD {s}\r\n",
    //                                 .{channel.name},
    //                             );
    //                             try client.queueWrite(mark_read);
    //                             try client.requestHistory(.after, channel);
    //                         },
    //                         .JOIN => {
    //                             // get the user
    //                             const src = msg.source() orelse continue :loop;
    //                             const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
    //                             const user = try client.getOrCreateUser(src[0..n]);
    //
    //                             // get the channel
    //                             var iter = msg.paramIterator();
    //                             const target = iter.next() orelse continue;
    //                             var channel = try client.getOrCreateChannel(target);
    //
    //                             // If it's our nick, we request chat history
    //                             if (mem.eql(u8, user.nick, client.nickname())) {
    //                                 try client.requestHistory(.after, channel);
    //                                 if (self.explicit_join) {
    //                                     self.selectChannelName(client, target);
    //                                     self.explicit_join = false;
    //                                 }
    //                             } else try channel.addMember(user, .{});
    //                         },
    //                         .MARKREAD => {
    //                             var iter = msg.paramIterator();
    //                             const target = iter.next() orelse continue;
    //                             const timestamp = iter.next() orelse continue;
    //                             const equal = std.mem.indexOfScalar(u8, timestamp, '=') orelse continue;
    //                             const last_read = zeit.instant(.{
    //                                 .source = .{
    //                                     .iso8601 = timestamp[equal + 1 ..],
    //                                 },
    //                             }) catch |err| {
    //                                 log.err("couldn't convert timestamp: {}", .{err});
    //                                 continue;
    //                             };
    //                             var channel = try client.getOrCreateChannel(target);
    //                             channel.last_read = last_read.unixTimestamp();
    //                             const last_msg = channel.messages.getLastOrNull() orelse continue;
    //                             const time = last_msg.time() orelse continue;
    //                             if (time.unixTimestamp() > channel.last_read)
    //                                 channel.has_unread = true
    //                             else
    //                                 channel.has_unread = false;
    //                         },
    //                         .PART => {
    //                             // get the user
    //                             const src = msg.source() orelse continue :loop;
    //                             const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
    //                             const user = try client.getOrCreateUser(src[0..n]);
    //
    //                             // get the channel
    //                             var iter = msg.paramIterator();
    //                             const target = iter.next() orelse continue;
    //
    //                             if (mem.eql(u8, user.nick, client.nickname())) {
    //                                 for (client.channels.items, 0..) |channel, i| {
    //                                     if (!mem.eql(u8, channel.name, target)) continue;
    //                                     var chan = client.channels.orderedRemove(i);
    //                                     self.state.buffers.selected_idx -|= 1;
    //                                     chan.deinit(self.alloc);
    //                                     break;
    //                                 }
    //                             } else {
    //                                 const channel = try client.getOrCreateChannel(target);
    //                                 channel.removeMember(user);
    //                             }
    //                         },
    //                         .PRIVMSG, .NOTICE => {
    //                             // syntax: <target> :<message>
    //                             const msg2: irc.Message = .{
    //                                 .bytes = try self.alloc.dupe(u8, msg.bytes),
    //                             };
    //                             var iter = msg2.paramIterator();
    //                             const target = blk: {
    //                                 const tgt = iter.next() orelse continue;
    //                                 if (mem.eql(u8, tgt, client.nickname())) {
    //                                     // If the target is us, it likely has our
    //                                     // hostname in it.
    //                                     const source = msg2.source() orelse continue;
    //                                     const n = mem.indexOfScalar(u8, source, '!') orelse source.len;
    //                                     break :blk source[0..n];
    //                                 } else break :blk tgt;
    //                             };
    //
    //                             // We handle batches separately. When we encounter a
    //                             // PRIVMSG from a batch, we use the original target
    //                             // from the batch start. We also never notify from a
    //                             // batched message. Batched messages also require
    //                             // sorting
    //                             var tag_iter = msg2.tagIterator();
    //                             while (tag_iter.next()) |tag| {
    //                                 if (mem.eql(u8, tag.key, "batch")) {
    //                                     const entry = client.batches.getEntry(tag.value) orelse @panic("TODO");
    //                                     var channel = entry.value_ptr.*;
    //                                     try channel.messages.append(msg2);
    //                                     std.sort.insertion(irc.Message, channel.messages.items, {}, irc.Message.compareTime);
    //                                     channel.at_oldest = false;
    //                                     const time = msg2.time() orelse continue;
    //                                     if (time.unixTimestamp() > channel.last_read) {
    //                                         channel.has_unread = true;
    //                                         const content = iter.next() orelse continue;
    //                                         if (std.mem.indexOf(u8, content, client.nickname())) |_| {
    //                                             channel.has_unread_highlight = true;
    //                                         }
    //                                     }
    //                                     break;
    //                                 }
    //                             } else {
    //                                 // standard handling
    //                                 var channel = try client.getOrCreateChannel(target);
    //                                 try channel.messages.append(msg2);
    //                                 const content = iter.next() orelse continue;
    //                                 var has_highlight = false;
    //                                 {
    //                                     const sender: []const u8 = blk: {
    //                                         const src = msg2.source() orelse break :blk "";
    //                                         const l = std.mem.indexOfScalar(u8, src, '!') orelse
    //                                             std.mem.indexOfScalar(u8, src, '@') orelse
    //                                             src.len;
    //                                         break :blk src[0..l];
    //                                     };
    //                                     try lua.onMessage(lua_state, client, channel.name, sender, content);
    //                                 }
    //                                 if (std.mem.indexOf(u8, content, client.nickname())) |_| {
    //                                     var buf: [64]u8 = undefined;
    //                                     const title_or_err = if (msg2.source()) |source|
    //                                         std.fmt.bufPrint(&buf, "{s} - {s}", .{ channel.name, source })
    //                                     else
    //                                         std.fmt.bufPrint(&buf, "{s}", .{channel.name});
    //                                     const title = title_or_err catch title: {
    //                                         const len = @min(buf.len, channel.name.len);
    //                                         @memcpy(buf[0..len], channel.name[0..len]);
    //                                         break :title buf[0..len];
    //                                     };
    //                                     try self.vx.notify(writer, title, content);
    //                                     has_highlight = true;
    //                                 }
    //                                 const time = msg2.time() orelse continue;
    //                                 if (time.unixTimestamp() > channel.last_read) {
    //                                     channel.has_unread_highlight = has_highlight;
    //                                     channel.has_unread = true;
    //                                 }
    //                             }
    //
    //                             // If we get a message from the current user mark the channel as
    //                             // read, since they must have just sent the message.
    //                             const sender: []const u8 = blk: {
    //                                 const src = msg2.source() orelse break :blk "";
    //                                 const l = std.mem.indexOfScalar(u8, src, '!') orelse
    //                                     std.mem.indexOfScalar(u8, src, '@') orelse
    //                                     src.len;
    //                                 break :blk src[0..l];
    //                             };
    //                             if (std.mem.eql(u8, sender, client.nickname())) {
    //                                 self.markSelectedChannelRead();
    //                             }
    //                         },
    //                     }
    //                 },
    //             }
    //         }
    //
    //         if (redraw) {
    //             try self.draw(&input);
    //             last_frame = std.time.milliTimestamp();
    //         }
    //     }
    // }

    pub fn connect(self: *App, cfg: irc.Client.Config) !void {
        const client = try self.alloc.create(irc.Client);
        client.* = try irc.Client.init(self.alloc, self, &self.write_queue, cfg);
        try self.clients.append(client);
    }

    pub fn nextChannel(self: *App) void {
        // When leaving a channel we mark it as read, so we make sure that's done
        // before we change to the new channel.
        self.markSelectedChannelRead();

        const state = self.state.buffers;
        if (state.selected_idx >= state.count - 1)
            self.state.buffers.selected_idx = 0
        else
            self.state.buffers.selected_idx +|= 1;
    }

    pub fn prevChannel(self: *App) void {
        // When leaving a channel we mark it as read, so we make sure that's done
        // before we change to the new channel.
        self.markSelectedChannelRead();

        switch (self.state.buffers.selected_idx) {
            0 => self.state.buffers.selected_idx = self.state.buffers.count - 1,
            else => self.state.buffers.selected_idx -|= 1,
        }
    }

    pub fn selectChannelName(self: *App, cl: *irc.Client, name: []const u8) void {
        var i: usize = 0;
        for (self.clients.items) |client| {
            i += 1;
            for (client.channels.items) |channel| {
                if (cl == client) {
                    if (std.mem.eql(u8, name, channel.name)) {
                        self.state.buffers.selected_idx = i;
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
                        self.state.buffers.selected_idx -|= 1;
                        chan.deinit(self.alloc);
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
