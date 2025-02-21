const std = @import("std");
const comlink = @import("comlink.zig");
const lua = @import("lua.zig");
const tls = @import("tls");
const vaxis = @import("vaxis");
const zeit = @import("zeit");
const bytepool = @import("pool.zig");

const testing = std.testing;
const mem = std.mem;
const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;
const Base64Encoder = std.base64.standard.Encoder;
pub const MessagePool = bytepool.BytePool(max_raw_msg_size * 4);
pub const Slice = MessagePool.Slice;

const assert = std.debug.assert;

const log = std.log.scoped(.irc);

/// maximum size message we can write
pub const maximum_message_size = 512;

/// maximum size message we can receive
const max_raw_msg_size = 512 + 8191; // see modernircdocs

pub const Buffer = union(enum) {
    client: *Client,
    channel: *Channel,
};

pub const Event = comlink.IrcEvent;

pub const Command = enum {
    RPL_WELCOME, // 001
    RPL_YOURHOST, // 002
    RPL_CREATED, // 003
    RPL_MYINFO, // 004
    RPL_ISUPPORT, // 005

    RPL_ENDOFWHO, // 315
    RPL_TOPIC, // 332
    RPL_WHOREPLY, // 352
    RPL_NAMREPLY, // 353
    RPL_WHOSPCRPL, // 354
    RPL_ENDOFNAMES, // 366

    RPL_LOGGEDIN, // 900
    RPL_SASLSUCCESS, // 903

    // Named commands
    AUTHENTICATE,
    AWAY,
    BATCH,
    BOUNCER,
    CAP,
    CHATHISTORY,
    JOIN,
    MARKREAD,
    NOTICE,
    PART,
    PRIVMSG,

    unknown,

    const map = std.StaticStringMap(Command).initComptime(.{
        .{ "001", .RPL_WELCOME },
        .{ "002", .RPL_YOURHOST },
        .{ "003", .RPL_CREATED },
        .{ "004", .RPL_MYINFO },
        .{ "005", .RPL_ISUPPORT },

        .{ "315", .RPL_ENDOFWHO },
        .{ "332", .RPL_TOPIC },
        .{ "352", .RPL_WHOREPLY },
        .{ "353", .RPL_NAMREPLY },
        .{ "354", .RPL_WHOSPCRPL },
        .{ "366", .RPL_ENDOFNAMES },

        .{ "900", .RPL_LOGGEDIN },
        .{ "903", .RPL_SASLSUCCESS },

        .{ "AUTHENTICATE", .AUTHENTICATE },
        .{ "AWAY", .AWAY },
        .{ "BATCH", .BATCH },
        .{ "BOUNCER", .BOUNCER },
        .{ "CAP", .CAP },
        .{ "CHATHISTORY", .CHATHISTORY },
        .{ "JOIN", .JOIN },
        .{ "MARKREAD", .MARKREAD },
        .{ "NOTICE", .NOTICE },
        .{ "PART", .PART },
        .{ "PRIVMSG", .PRIVMSG },
    });

    pub fn parse(cmd: []const u8) Command {
        return map.get(cmd) orelse .unknown;
    }
};

pub const Channel = struct {
    client: *Client,
    name: []const u8,
    topic: ?[]const u8 = null,
    members: std.ArrayList(Member),
    in_flight: struct {
        who: bool = false,
        names: bool = false,
    } = .{},

    messages: std.ArrayList(Message),
    history_requested: bool = false,
    who_requested: bool = false,
    at_oldest: bool = false,
    last_read: i64 = 0,
    has_unread: bool = false,
    has_unread_highlight: bool = false,

    has_mouse: bool = false,

    view: vxfw.SplitView,
    member_view: vxfw.ListView,
    text_field: vxfw.TextField,

    scroll: struct {
        /// Line offset from the bottom message
        offset: u16 = 0,
        /// Message offset into the list of messages. We use this to lock the viewport if we have a
        /// scroll. Otherwise, when offset == 0 this is effectively ignored (and should be 0)
        msg_offset: ?u16 = null,

        /// Pending scroll we have to handle while drawing. This could be up or down. By convention
        /// we say positive is a scroll up.
        pending: i16 = 0,
    } = .{},

    pub const Member = struct {
        user: *User,

        /// Highest channel membership prefix (or empty space if no prefix)
        prefix: u8,

        pub fn compare(_: void, lhs: Member, rhs: Member) bool {
            return if (lhs.prefix != ' ' and rhs.prefix == ' ')
                true
            else if (lhs.prefix == ' ' and rhs.prefix != ' ')
                false
            else
                std.ascii.orderIgnoreCase(lhs.user.nick, rhs.user.nick).compare(.lt);
        }

        pub fn widget(self: *Member) vxfw.Widget {
            return .{
                .userdata = self,
                .drawFn = Member.draw,
            };
        }

        pub fn draw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
            const self: *Member = @ptrCast(@alignCast(ptr));
            const style: vaxis.Style = if (self.user.away)
                .{ .dim = true }
            else
                .{ .fg = self.user.color };
            var prefix = try ctx.arena.alloc(u8, 1);
            prefix[0] = self.prefix;
            const text: vxfw.RichText = .{
                .text = &.{
                    .{ .text = prefix, .style = style },
                    .{ .text = self.user.nick, .style = style },
                },
                .softwrap = false,
            };
            return text.draw(ctx);
        }
    };

    pub fn init(
        self: *Channel,
        gpa: Allocator,
        client: *Client,
        name: []const u8,
        unicode: *const vaxis.Unicode,
    ) Allocator.Error!void {
        self.* = .{
            .name = try gpa.dupe(u8, name),
            .members = std.ArrayList(Channel.Member).init(gpa),
            .messages = std.ArrayList(Message).init(gpa),
            .client = client,
            .view = .{
                .lhs = self.contentWidget(),
                .rhs = self.member_view.widget(),
                .width = 16,
                .constrain = .rhs,
            },
            .member_view = .{
                .children = .{
                    .builder = .{
                        .userdata = self,
                        .buildFn = Channel.buildMemberList,
                    },
                },
                .draw_cursor = false,
            },
            .text_field = vxfw.TextField.init(gpa, unicode),
        };
    }

    pub fn deinit(self: *Channel, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        self.members.deinit();
        if (self.topic) |topic| {
            alloc.free(topic);
        }
        for (self.messages.items) |msg| {
            alloc.free(msg.bytes);
        }
        self.messages.deinit();
        self.text_field.deinit();
    }

    pub fn compare(_: void, lhs: *Channel, rhs: *Channel) bool {
        return std.ascii.orderIgnoreCase(lhs.name, rhs.name).compare(std.math.CompareOperator.lt);
    }

    pub fn compareRecentMessages(self: *Channel, lhs: Member, rhs: Member) bool {
        var l: i64 = 0;
        var r: i64 = 0;
        var iter = std.mem.reverseIterator(self.messages.items);
        while (iter.next()) |msg| {
            if (msg.source()) |source| {
                const bang = std.mem.indexOfScalar(u8, source, '!') orelse source.len;
                const nick = source[0..bang];

                if (l == 0 and msg.time() != null and std.mem.eql(u8, lhs.user.nick, nick)) {
                    l = msg.time().?.unixTimestamp();
                } else if (r == 0 and msg.time() != null and std.mem.eql(u8, rhs.user.nick, nick))
                    r = msg.time().?.unixTimestamp();
            }
            if (l > 0 and r > 0) break;
        }
        return l < r;
    }

    pub fn nameWidget(self: *Channel, selected: bool) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Channel.typeErasedEventHandler,
            .drawFn = if (selected)
                Channel.typeErasedDrawNameSelected
            else
                Channel.typeErasedDrawName,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                try ctx.setMouseShape(.pointer);
                if (mouse.type == .press and mouse.button == .left) {
                    self.client.app.selectBuffer(.{ .channel = self });
                    try ctx.requestFocus(self.text_field.widget());
                    const buf = &self.client.app.title_buf;
                    const suffix = " - comlink";
                    if (self.name.len + suffix.len <= buf.len) {
                        const title = try std.fmt.bufPrint(buf, "{s}{s}", .{ self.name, suffix });
                        try ctx.setTitle(title);
                    } else {
                        const title = try std.fmt.bufPrint(
                            buf,
                            "{s}{s}",
                            .{ self.name[0 .. buf.len - suffix.len], suffix },
                        );
                        try ctx.setTitle(title);
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                self.has_mouse = true;
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                self.has_mouse = false;
            },
            else => {},
        }
    }

    pub fn drawName(self: *Channel, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
        var style: vaxis.Style = .{};
        if (selected) style.reverse = true;
        if (self.has_mouse) style.bg = .{ .index = 8 };

        const text: vxfw.RichText = .{
            .text = &.{
                .{ .text = "  " },
                .{ .text = self.name, .style = style },
            },
            .softwrap = false,
        };
        var surface = try text.draw(ctx);
        // Replace the widget reference so we can handle the events
        surface.widget = self.nameWidget(selected);
        return surface;
    }

    fn typeErasedDrawName(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, false);
    }

    fn typeErasedDrawNameSelected(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, true);
    }

    pub fn sortMembers(self: *Channel) void {
        std.sort.insertion(Member, self.members.items, {}, Member.compare);
    }

    pub fn addMember(self: *Channel, user: *User, args: struct {
        prefix: ?u8 = null,
        sort: bool = true,
    }) Allocator.Error!void {
        if (args.prefix) |p| {
            log.debug("adding member: nick={s}, prefix={c}", .{ user.nick, p });
        }
        for (self.members.items) |*member| {
            if (user == member.user) {
                // Update the prefix for an existing member if the prefix is
                // known
                if (args.prefix) |p| member.prefix = p;
                return;
            }
        }

        try self.members.append(.{ .user = user, .prefix = args.prefix orelse ' ' });

        if (args.sort) {
            self.sortMembers();
        }
    }

    pub fn removeMember(self: *Channel, user: *User) void {
        for (self.members.items, 0..) |member, i| {
            if (user == member.user) {
                _ = self.members.orderedRemove(i);
                return;
            }
        }
    }

    /// issue a MARKREAD command for this channel. The most recent message in the channel will be used as
    /// the last read time
    pub fn markRead(self: *Channel) !void {
        if (!self.has_unread) return;

        self.has_unread = false;
        self.has_unread_highlight = false;
        const last_msg = self.messages.getLast();
        const time_tag = last_msg.getTag("time") orelse return;
        try self.client.print(
            "MARKREAD {s} timestamp={s}\r\n",
            .{
                self.name,
                time_tag,
            },
        );
    }

    pub fn contentWidget(self: *Channel) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = Channel.typeErasedViewDraw,
        };
    }

    fn typeErasedViewDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        if (!self.who_requested) {
            try self.client.whox(self);
        }

        const max = ctx.max.size();
        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        {
            // Draw the topic
            const topic: vxfw.Text = .{
                .text = self.topic orelse "",
                .softwrap = false,
            };

            const topic_sub: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = 0 },
                .surface = try topic.draw(ctx),
            };

            try children.append(topic_sub);

            // Draw a border below the topic
            const bot = "─";
            var writer = try std.ArrayList(u8).initCapacity(ctx.arena, bot.len * max.width);
            try writer.writer().writeBytesNTimes(bot, max.width);

            const border: vxfw.Text = .{
                .text = writer.items,
                .softwrap = false,
            };

            const topic_border: vxfw.SubSurface = .{
                .origin = .{ .col = 0, .row = 1 },
                .surface = try border.draw(ctx),
            };
            try children.append(topic_border);
        }

        const msg_view_ctx = ctx.withConstraints(.{ .height = 0, .width = 0 }, .{
            .height = max.height - 4,
            .width = max.width,
        });
        const message_view = try self.drawMessageView(msg_view_ctx);
        try children.append(.{
            .origin = .{ .row = 2, .col = 0 },
            .surface = message_view,
        });

        // Draw the text field
        try children.append(.{
            .origin = .{ .col = 0, .row = max.height - 1 },
            .surface = try self.text_field.draw(ctx),
        });

        return .{
            .size = max,
            .widget = self.contentWidget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn handleMessageViewEvent(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                if (mouse.button == .wheel_down) {
                    self.scroll.pending -|= 3;
                    ctx.consume_event = true;
                }
                if (mouse.button == .wheel_up) {
                    self.scroll.pending +|= 3;
                    ctx.consume_event = true;
                }
                if (self.scroll.pending != 0) {
                    return self.doScroll(ctx);
                }
            },
            .tick => try self.doScroll(ctx),
            else => {},
        }
    }

    /// Consumes any pending scrolls and schedules another tick if needed
    fn doScroll(self: *Channel, ctx: *vxfw.EventContext) anyerror!void {
        defer {
            // At the end of this function, we anchor our msg_offset if we have any amount of
            // scroll. This prevents new messages from automatically scrolling us
            if (self.scroll.offset > 0 and self.scroll.msg_offset == null) {
                self.scroll.msg_offset = @intCast(self.messages.items.len);
            }
            // If we have no offset, we reset our anchor
            if (self.scroll.offset == 0) {
                self.scroll.msg_offset = null;
            }
        }
        const animation_tick: u32 = 30;
        // No pending scroll. Return early
        if (self.scroll.pending == 0) return;

        // Scroll up
        if (self.scroll.pending > 0) {
            // TODO: check if we need to get more history
            // TODO: cehck if we are at oldest, and shouldn't scroll up anymore

            // Consume 1 line, and schedule a tick
            self.scroll.offset += 1;
            self.scroll.pending -= 1;
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }

        // From here, we only scroll down. First, we check if we are at the bottom already. If we
        // are, we have nothing to do
        if (self.scroll.offset == 0) {
            // Already at bottom. Nothing to do
            self.scroll.pending = 0;
            return;
        }

        // Scroll down
        if (self.scroll.pending < 0) {
            // Consume 1 line, and schedule a tick
            self.scroll.offset -= 1;
            self.scroll.pending += 1;
            ctx.redraw = true;
            return ctx.tick(animation_tick, self.messageViewWidget());
        }
    }

    fn messageViewWidget(self: *Channel) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Channel.handleMessageViewEvent,
            .drawFn = Channel.typeErasedDrawMessageView,
        };
    }

    fn typeErasedDrawMessageView(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Channel = @ptrCast(@alignCast(ptr));
        return self.drawMessageView(ctx);
    }

    fn drawMessageView(self: *Channel, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const max = ctx.max.size();
        if (max.width == 0 or max.height == 0) {
            return .{
                .size = max,
                .widget = self.messageViewWidget(),
                .buffer = &.{},
                .children = &.{},
            };
        }

        var children = std.ArrayList(vxfw.SubSurface).init(ctx.arena);

        // Row is the row we are printing on. We add the offset to achieve our scroll location
        var row: i17 = max.height + self.scroll.offset;

        const offset = self.scroll.msg_offset orelse self.messages.items.len;

        var iter = std.mem.reverseIterator(self.messages.items[0..offset]);
        const gutter_width = 6;
        while (iter.next()) |msg| {
            // Break if we have gone past the top of the screen
            if (row < 0) break;

            // Draw the message so we have it's wrapped height
            const text: vxfw.Text = .{ .text = msg.bytes };
            const child_ctx = ctx.withConstraints(
                .{ .height = 0, .width = 0 },
                .{ .width = max.width -| gutter_width, .height = null },
            );
            const surface = try text.draw(child_ctx);

            // Adjust the row we print on for the wrapped height of this message
            row -= surface.size.height;
            try children.append(.{
                .origin = .{ .row = row, .col = gutter_width },
                .surface = surface,
            });

            // If we have a time, print it in the gutter
            if (msg.localTime(&self.client.app.tz)) |instant| {
                const time = instant.time();
                const buf = try std.fmt.allocPrint(
                    ctx.arena,
                    "{d:0>2}:{d:0>2}",
                    .{ time.hour, time.minute },
                );
                const time_text: vxfw.Text = .{
                    .text = buf,
                    .style = .{ .dim = true },
                    .softwrap = false,
                };
                try children.append(.{
                    .origin = .{ .row = row, .col = 0 },
                    .surface = try time_text.draw(child_ctx),
                });
            }
        }

        return .{
            .size = max,
            .widget = self.messageViewWidget(),
            .buffer = &.{},
            .children = children.items,
        };
    }

    fn buildMemberList(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Channel = @ptrCast(@alignCast(ptr));
        if (idx < self.members.items.len) {
            return self.members.items[idx].widget();
        }
        return null;
    }
};

pub const User = struct {
    nick: []const u8,
    away: bool = false,
    color: vaxis.Color = .default,
    real_name: ?[]const u8 = null,

    pub fn deinit(self: *const User, alloc: std.mem.Allocator) void {
        alloc.free(self.nick);
        if (self.real_name) |realname| alloc.free(realname);
    }
};

/// an irc message
pub const Message = struct {
    bytes: []const u8,

    pub const ParamIterator = struct {
        params: ?[]const u8,
        index: usize = 0,

        pub fn next(self: *ParamIterator) ?[]const u8 {
            const params = self.params orelse return null;
            if (self.index >= params.len) return null;

            // consume leading whitespace
            while (self.index < params.len) {
                if (params[self.index] != ' ') break;
                self.index += 1;
            }

            const start = self.index;
            if (start >= params.len) return null;

            // If our first byte is a ':', we return the rest of the string as a
            // single param (or the empty string)
            if (params[start] == ':') {
                self.index = params.len;
                if (start == params.len - 1) {
                    return "";
                }
                return params[start + 1 ..];
            }

            // Find the first index of space. If we don't have any, the reset of
            // the line is the last param
            self.index = std.mem.indexOfScalarPos(u8, params, self.index, ' ') orelse {
                defer self.index = params.len;
                return params[start..];
            };

            return params[start..self.index];
        }
    };

    pub const Tag = struct {
        key: []const u8,
        value: []const u8,
    };

    pub const TagIterator = struct {
        tags: []const u8,
        index: usize = 0,

        // tags are a list of key=value pairs delimited by semicolons.
        // key[=value] [; key[=value]]
        pub fn next(self: *TagIterator) ?Tag {
            if (self.index >= self.tags.len) return null;

            // find next delimiter
            const end = std.mem.indexOfScalarPos(u8, self.tags, self.index, ';') orelse self.tags.len;
            var kv_delim = std.mem.indexOfScalarPos(u8, self.tags, self.index, '=') orelse end;
            // it's possible to have tags like this:
            //     @bot;account=botaccount;+typing=active
            // where the first tag doesn't have a value. Guard against the
            // kv_delim being past the end position
            if (kv_delim > end) kv_delim = end;

            defer self.index = end + 1;

            return .{
                .key = self.tags[self.index..kv_delim],
                .value = if (end == kv_delim) "" else self.tags[kv_delim + 1 .. end],
            };
        }
    };

    pub fn tagIterator(msg: Message) TagIterator {
        const src = msg.bytes;
        if (src[0] != '@') return .{ .tags = "" };

        assert(src.len > 1);
        const n = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse src.len;
        return .{ .tags = src[1..n] };
    }

    pub fn source(msg: Message) ?[]const u8 {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return null;
        }

        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // Start of source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
            return src[i..end];
        }

        return null;
    }

    pub fn command(msg: Message) Command {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            assert(src.len > 1);
            i = std.mem.indexOfScalarPos(u8, src, 1, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .unknown;
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        assert(src.len > i);
        // Find next space
        const end = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse src.len;
        return Command.parse(src[i..end]);
    }

    pub fn paramIterator(msg: Message) ParamIterator {
        const src = msg.bytes;
        var i: usize = 0;

        // get past tags
        if (src[0] == '@') {
            i = std.mem.indexOfScalarPos(u8, src, 0, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past source
        if (src[i] == ':') {
            assert(src.len > i);
            i += 1;
            i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };
        }
        // consume whitespace
        while (i < src.len) : (i += 1) {
            if (src[i] != ' ') break;
        }

        // get past command
        i = std.mem.indexOfScalarPos(u8, src, i, ' ') orelse return .{ .params = "" };

        assert(src.len > i);
        return .{ .params = src[i + 1 ..] };
    }

    /// Returns the value of the tag 'key', if present
    pub fn getTag(self: Message, key: []const u8) ?[]const u8 {
        var tag_iter = self.tagIterator();
        while (tag_iter.next()) |tag| {
            if (!std.mem.eql(u8, tag.key, key)) continue;
            return tag.value;
        }
        return null;
    }

    pub fn time(self: Message) ?zeit.Instant {
        const val = self.getTag("time") orelse return null;

        // Return null if we can't parse the time
        const instant = zeit.instant(.{
            .source = .{ .iso8601 = val },
            .timezone = &zeit.utc,
        }) catch return null;

        return instant;
    }

    pub fn localTime(self: Message, tz: *const zeit.TimeZone) ?zeit.Instant {
        const utc = self.time() orelse return null;
        return utc.in(tz);
    }

    pub fn compareTime(_: void, lhs: Message, rhs: Message) bool {
        const lhs_time = lhs.time() orelse return false;
        const rhs_time = rhs.time() orelse return false;

        return lhs_time.timestamp_ns < rhs_time.timestamp_ns;
    }
};

pub const Client = struct {
    pub const Config = struct {
        user: []const u8,
        nick: []const u8,
        password: []const u8,
        real_name: []const u8,
        server: []const u8,
        port: ?u16,
        network_id: ?[]const u8 = null,
        network_nick: ?[]const u8 = null,
        name: ?[]const u8 = null,
        tls: bool = true,
        lua_table: i32,
    };

    pub const Capabilities = struct {
        @"away-notify": bool = false,
        batch: bool = false,
        @"echo-message": bool = false,
        @"message-tags": bool = false,
        sasl: bool = false,
        @"server-time": bool = false,

        @"draft/chathistory": bool = false,
        @"draft/no-implicit-names": bool = false,
        @"draft/read-marker": bool = false,

        @"soju.im/bouncer-networks": bool = false,
        @"soju.im/bouncer-networks-notify": bool = false,
    };

    /// ISupport are features only advertised via ISUPPORT that we care about
    pub const ISupport = struct {
        whox: bool = false,
        prefix: []const u8 = "",
    };

    alloc: std.mem.Allocator,
    app: *comlink.App,
    client: tls.Connection(std.net.Stream),
    stream: std.net.Stream,
    config: Config,

    channels: std.ArrayList(*Channel),
    users: std.StringHashMap(*User),

    should_close: bool = false,
    status: enum {
        connected,
        disconnected,
    } = .disconnected,

    caps: Capabilities = .{},
    supports: ISupport = .{},

    batches: std.StringHashMap(*Channel),
    write_queue: *comlink.WriteQueue,

    thread: ?std.Thread = null,

    redraw: std.atomic.Value(bool),
    fifo: std.fifo.LinearFifo(Event, .Dynamic),
    fifo_mutex: std.Thread.Mutex,

    has_mouse: bool,

    pub fn init(
        alloc: std.mem.Allocator,
        app: *comlink.App,
        wq: *comlink.WriteQueue,
        cfg: Config,
    ) !Client {
        return .{
            .alloc = alloc,
            .app = app,
            .client = undefined,
            .stream = undefined,
            .config = cfg,
            .channels = std.ArrayList(*Channel).init(alloc),
            .users = std.StringHashMap(*User).init(alloc),
            .batches = std.StringHashMap(*Channel).init(alloc),
            .write_queue = wq,
            .redraw = std.atomic.Value(bool).init(false),
            .fifo = std.fifo.LinearFifo(Event, .Dynamic).init(alloc),
            .fifo_mutex = .{},
            .has_mouse = false,
        };
    }

    pub fn deinit(self: *Client) void {
        self.should_close = true;
        if (self.status == .connected) {
            self.write("PING comlink\r\n") catch |err|
                log.err("couldn't close tls conn: {}", .{err});
            if (self.thread) |thread| {
                thread.detach();
                self.thread = null;
            }
        }
        // id gets allocated in the main thread. We need to deallocate it here if
        // we have one
        if (self.config.network_id) |id| self.alloc.free(id);
        if (self.config.name) |name| self.alloc.free(name);

        if (self.config.network_nick) |nick| self.alloc.free(nick);

        for (self.channels.items) |channel| {
            channel.deinit(self.alloc);
            self.alloc.destroy(channel);
        }
        self.channels.deinit();

        var user_iter = self.users.valueIterator();
        while (user_iter.next()) |user| {
            user.*.deinit(self.alloc);
            self.alloc.destroy(user.*);
        }
        self.users.deinit();
        self.alloc.free(self.supports.prefix);
        var batches = self.batches;
        var iter = batches.keyIterator();
        while (iter.next()) |key| {
            self.alloc.free(key.*);
        }
        batches.deinit();
        self.fifo.deinit();
    }

    pub fn view(self: *Client) vxfw.Widget {
        return .{
            .userdata = self,
            .drawFn = Client.typeErasedViewDraw,
        };
    }

    fn typeErasedViewDraw(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        _ = ptr;
        const text: vxfw.Text = .{ .text = "content" };
        return text.draw(ctx);
    }

    pub fn nameWidget(self: *Client, selected: bool) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Client.typeErasedEventHandler,
            .drawFn = if (selected)
                Client.typeErasedDrawNameSelected
            else
                Client.typeErasedDrawName,
        };
    }

    pub fn drawName(self: *Client, ctx: vxfw.DrawContext, selected: bool) Allocator.Error!vxfw.Surface {
        var style: vaxis.Style = .{};
        if (selected) style.reverse = true;
        if (self.has_mouse) style.bg = .{ .index = 8 };

        const name = self.config.name orelse self.config.server;

        const text: vxfw.RichText = .{
            .text = &.{
                .{ .text = name, .style = style },
            },
            .softwrap = false,
        };
        var surface = try text.draw(ctx);
        // Replace the widget reference so we can handle the events
        surface.widget = self.nameWidget(selected);
        return surface;
    }

    fn typeErasedDrawName(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, false);
    }

    fn typeErasedDrawNameSelected(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!vxfw.Surface {
        const self: *Client = @ptrCast(@alignCast(ptr));
        return self.drawName(ctx, true);
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Client = @ptrCast(@alignCast(ptr));
        switch (event) {
            .mouse => |mouse| {
                try ctx.setMouseShape(.pointer);
                if (mouse.type == .press and mouse.button == .left) {
                    self.app.selectBuffer(.{ .client = self });
                    const buf = &self.app.title_buf;
                    const suffix = " - comlink";
                    const name = self.config.name orelse self.config.server;
                    if (name.len + suffix.len <= buf.len) {
                        const title = try std.fmt.bufPrint(buf, "{s}{s}", .{ name, suffix });
                        try ctx.setTitle(title);
                    } else {
                        const title = try std.fmt.bufPrint(
                            buf,
                            "{s}{s}",
                            .{ name[0 .. buf.len - suffix.len], suffix },
                        );
                        try ctx.setTitle(title);
                    }
                    return ctx.consumeAndRedraw();
                }
            },
            .mouse_enter => {
                try ctx.setMouseShape(.pointer);
                self.has_mouse = true;
            },
            .mouse_leave => {
                try ctx.setMouseShape(.default);
                self.has_mouse = false;
            },
            else => {},
        }
    }

    pub fn drainFifo(self: *Client, ctx: *vxfw.EventContext) void {
        self.fifo_mutex.lock();
        defer self.fifo_mutex.unlock();
        while (self.fifo.readItem()) |item| {
            // We redraw if we have any items
            ctx.redraw = true;
            self.handleEvent(item) catch |err| {
                log.err("error: {}", .{err});
            };
        }
    }

    pub fn handleEvent(self: *Client, event: Event) !void {
        const msg: Message = .{ .bytes = event.msg.slice() };
        const client = event.client;
        defer event.msg.deinit();
        switch (msg.command()) {
            .unknown => {},
            .CAP => {
                // syntax: <client> <ACK/NACK> :caps
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const ack_or_nak = iter.next() orelse return;
                const caps = iter.next() orelse return;
                var cap_iter = mem.splitScalar(u8, caps, ' ');
                while (cap_iter.next()) |cap| {
                    if (mem.eql(u8, ack_or_nak, "ACK")) {
                        client.ack(cap);
                        if (mem.eql(u8, cap, "sasl"))
                            try client.queueWrite("AUTHENTICATE PLAIN\r\n");
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
                    const config = client.config;
                    const sasl = try std.fmt.bufPrint(
                        &buf,
                        "{s}\x00{s}\x00{s}",
                        .{ config.user, config.nick, config.password },
                    );

                    // Create a buffer big enough for the base64 encoded string
                    const b64_buf = try self.alloc.alloc(u8, Base64Encoder.calcSize(sasl.len));
                    defer self.alloc.free(b64_buf);
                    const encoded = Base64Encoder.encode(b64_buf, sasl);
                    // Make our message
                    const auth = try std.fmt.bufPrint(
                        &buf,
                        "AUTHENTICATE {s}\r\n",
                        .{encoded},
                    );
                    try client.queueWrite(auth);
                    if (config.network_id) |id| {
                        const bind = try std.fmt.bufPrint(
                            &buf,
                            "BOUNCER BIND {s}\r\n",
                            .{id},
                        );
                        try client.queueWrite(bind);
                    }
                    try client.queueWrite("CAP END\r\n");
                }
            },
            .RPL_WELCOME => {
                const now = try zeit.instant(.{});
                var now_buf: [30]u8 = undefined;
                const now_fmt = try now.time().bufPrint(&now_buf, .rfc3339);

                const past = try now.subtract(.{ .days = 7 });
                var past_buf: [30]u8 = undefined;
                const past_fmt = try past.time().bufPrint(&past_buf, .rfc3339);

                var buf: [128]u8 = undefined;
                const targets = try std.fmt.bufPrint(
                    &buf,
                    "CHATHISTORY TARGETS timestamp={s} timestamp={s} 50\r\n",
                    .{ now_fmt, past_fmt },
                );
                try client.queueWrite(targets);
                // on_connect callback
                try lua.onConnect(self.app.lua, client);
            },
            .RPL_YOURHOST => {},
            .RPL_CREATED => {},
            .RPL_MYINFO => {},
            .RPL_ISUPPORT => {
                // syntax: <client> <token>[ <token>] :are supported
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                while (iter.next()) |token| {
                    if (mem.eql(u8, token, "WHOX"))
                        client.supports.whox = true
                    else if (mem.startsWith(u8, token, "PREFIX")) {
                        const prefix = blk: {
                            const idx = mem.indexOfScalar(u8, token, ')') orelse
                                // default is "@+"
                                break :blk try self.alloc.dupe(u8, "@+");
                            break :blk try self.alloc.dupe(u8, token[idx + 1 ..]);
                        };
                        client.supports.prefix = prefix;
                    }
                }
            },
            .RPL_LOGGEDIN => {},
            .RPL_TOPIC => {
                // syntax: <client> <channel> :<topic>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client ("*")
                const channel_name = iter.next() orelse return; // channel
                const topic = iter.next() orelse return; // topic

                var channel = try client.getOrCreateChannel(channel_name);
                if (channel.topic) |old_topic| {
                    self.alloc.free(old_topic);
                }
                channel.topic = try self.alloc.dupe(u8, topic);
            },
            .RPL_SASLSUCCESS => {},
            .RPL_WHOREPLY => {
                // syntax: <client> <channel> <username> <host> <server> <nick> <flags> :<hopcount> <real name>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                if (mem.eql(u8, channel_name, "*")) return;
                _ = iter.next() orelse return; // username
                _ = iter.next() orelse return; // host
                _ = iter.next() orelse return; // server
                const nick = iter.next() orelse return; // nick
                const flags = iter.next() orelse return; // flags

                const user_ptr = try client.getOrCreateUser(nick);
                if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                var channel = try client.getOrCreateChannel(channel_name);

                const prefix = for (flags) |c| {
                    if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
                        break c;
                    }
                } else ' ';

                try channel.addMember(user_ptr, .{ .prefix = prefix });
            },
            .RPL_WHOSPCRPL => {
                // syntax: <client> <channel> <nick> <flags> :<realname>
                var iter = msg.paramIterator();
                _ = iter.next() orelse return;
                const channel_name = iter.next() orelse return; // channel
                const nick = iter.next() orelse return;
                const flags = iter.next() orelse return;

                const user_ptr = try client.getOrCreateUser(nick);
                if (iter.next()) |real_name| {
                    if (user_ptr.real_name) |old_name| {
                        self.alloc.free(old_name);
                    }
                    user_ptr.real_name = try self.alloc.dupe(u8, real_name);
                }
                if (mem.indexOfScalar(u8, flags, 'G')) |_| user_ptr.away = true;
                var channel = try client.getOrCreateChannel(channel_name);

                const prefix = for (flags) |c| {
                    if (std.mem.indexOfScalar(u8, client.supports.prefix, c)) |_| {
                        break c;
                    }
                } else ' ';

                try channel.addMember(user_ptr, .{ .prefix = prefix });
            },
            .RPL_ENDOFWHO => {
                // syntax: <client> <mask> :End of WHO list
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                if (mem.eql(u8, channel_name, "*")) return;
                var channel = try client.getOrCreateChannel(channel_name);
                channel.in_flight.who = false;
            },
            .RPL_NAMREPLY => {
                // syntax: <client> <symbol> <channel> :[<prefix>]<nick>{ [<prefix>]<nick>}
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                _ = iter.next() orelse return; // symbol
                const channel_name = iter.next() orelse return; // channel
                const names = iter.next() orelse return;
                var channel = try client.getOrCreateChannel(channel_name);
                var name_iter = std.mem.splitScalar(u8, names, ' ');
                while (name_iter.next()) |name| {
                    const nick, const prefix = for (client.supports.prefix) |ch| {
                        if (name[0] == ch) {
                            break .{ name[1..], name[0] };
                        }
                    } else .{ name, ' ' };

                    if (prefix != ' ') {
                        log.debug("HAS PREFIX {s}", .{name});
                    }

                    const user_ptr = try client.getOrCreateUser(nick);

                    try channel.addMember(user_ptr, .{ .prefix = prefix, .sort = false });
                }

                channel.sortMembers();
            },
            .RPL_ENDOFNAMES => {
                // syntax: <client> <channel> :End of /NAMES list
                var iter = msg.paramIterator();
                _ = iter.next() orelse return; // client
                const channel_name = iter.next() orelse return; // channel
                var channel = try client.getOrCreateChannel(channel_name);
                channel.in_flight.names = false;
            },
            .BOUNCER => {
                var iter = msg.paramIterator();
                while (iter.next()) |param| {
                    if (mem.eql(u8, param, "NETWORK")) {
                        const id = iter.next() orelse continue;
                        const attr = iter.next() orelse continue;
                        // check if we already have this network
                        for (self.app.clients.items, 0..) |cl, i| {
                            if (cl.config.network_id) |net_id| {
                                if (mem.eql(u8, net_id, id)) {
                                    if (mem.eql(u8, attr, "*")) {
                                        // * means the network was
                                        // deleted
                                        cl.deinit();
                                        _ = self.app.clients.swapRemove(i);
                                    }
                                    return;
                                }
                            }
                        }

                        var cfg = client.config;
                        cfg.network_id = try self.alloc.dupe(u8, id);

                        var attr_iter = std.mem.splitScalar(u8, attr, ';');
                        while (attr_iter.next()) |kv| {
                            const n = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
                            const key = kv[0..n];
                            if (mem.eql(u8, key, "name"))
                                cfg.name = try self.alloc.dupe(u8, kv[n + 1 ..])
                            else if (mem.eql(u8, key, "nickname"))
                                cfg.network_nick = try self.alloc.dupe(u8, kv[n + 1 ..]);
                        }
                        try self.app.connect(cfg);
                    }
                }
            },
            .AWAY => {
                const src = msg.source() orelse return;
                var iter = msg.paramIterator();
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);
                // If there are any params, the user is away. Otherwise
                // they are back.
                user.away = if (iter.next()) |_| true else false;
            },
            .BATCH => {
                var iter = msg.paramIterator();
                const tag = iter.next() orelse return;
                switch (tag[0]) {
                    '+' => {
                        const batch_type = iter.next() orelse return;
                        if (mem.eql(u8, batch_type, "chathistory")) {
                            const target = iter.next() orelse return;
                            var channel = try client.getOrCreateChannel(target);
                            channel.at_oldest = true;
                            const duped_tag = try self.alloc.dupe(u8, tag[1..]);
                            try client.batches.put(duped_tag, channel);
                        }
                    },
                    '-' => {
                        const key = client.batches.getKey(tag[1..]) orelse return;
                        var chan = client.batches.get(key) orelse @panic("key should exist here");
                        chan.history_requested = false;
                        _ = client.batches.remove(key);
                        self.alloc.free(key);
                    },
                    else => {},
                }
            },
            .CHATHISTORY => {
                var iter = msg.paramIterator();
                const should_targets = iter.next() orelse return;
                if (!mem.eql(u8, should_targets, "TARGETS")) return;
                const target = iter.next() orelse return;
                // we only add direct messages, not more channels
                assert(target.len > 0);
                if (target[0] == '#') return;

                var channel = try client.getOrCreateChannel(target);
                const user_ptr = try client.getOrCreateUser(target);
                const me_ptr = try client.getOrCreateUser(client.nickname());
                try channel.addMember(user_ptr, .{});
                try channel.addMember(me_ptr, .{});
                // we set who_requested so we don't try to request
                // who on DMs
                channel.who_requested = true;
                var buf: [128]u8 = undefined;
                const mark_read = try std.fmt.bufPrint(
                    &buf,
                    "MARKREAD {s}\r\n",
                    .{channel.name},
                );
                try client.queueWrite(mark_read);
                try client.requestHistory(.after, channel);
            },
            .JOIN => {
                // get the user
                const src = msg.source() orelse return;
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);

                // get the channel
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;
                var channel = try client.getOrCreateChannel(target);

                // If it's our nick, we request chat history
                if (mem.eql(u8, user.nick, client.nickname())) {
                    try client.requestHistory(.after, channel);
                    if (self.app.explicit_join) {
                        self.app.selectChannelName(client, target);
                        self.app.explicit_join = false;
                    }
                } else try channel.addMember(user, .{});
            },
            .MARKREAD => {
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;
                const timestamp = iter.next() orelse return;
                const equal = std.mem.indexOfScalar(u8, timestamp, '=') orelse return;
                const last_read = zeit.instant(.{
                    .source = .{
                        .iso8601 = timestamp[equal + 1 ..],
                    },
                }) catch |err| {
                    log.err("couldn't convert timestamp: {}", .{err});
                    return;
                };
                var channel = try client.getOrCreateChannel(target);
                channel.last_read = last_read.unixTimestamp();
                const last_msg = channel.messages.getLastOrNull() orelse return;
                const time = last_msg.time() orelse return;
                if (time.unixTimestamp() > channel.last_read)
                    channel.has_unread = true
                else
                    channel.has_unread = false;
            },
            .PART => {
                // get the user
                const src = msg.source() orelse return;
                const n = std.mem.indexOfScalar(u8, src, '!') orelse src.len;
                const user = try client.getOrCreateUser(src[0..n]);

                // get the channel
                var iter = msg.paramIterator();
                const target = iter.next() orelse return;

                if (mem.eql(u8, user.nick, client.nickname())) {
                    for (client.channels.items, 0..) |channel, i| {
                        if (!mem.eql(u8, channel.name, target)) continue;
                        var chan = client.channels.orderedRemove(i);
                        self.app.state.buffers.selected_idx -|= 1;
                        chan.deinit(self.app.alloc);
                        self.alloc.destroy(chan);
                        break;
                    }
                } else {
                    const channel = try client.getOrCreateChannel(target);
                    channel.removeMember(user);
                }
            },
            .PRIVMSG, .NOTICE => {
                // syntax: <target> :<message>
                const msg2: Message = .{
                    .bytes = try self.app.alloc.dupe(u8, msg.bytes),
                };
                var iter = msg2.paramIterator();
                const target = blk: {
                    const tgt = iter.next() orelse return;
                    if (mem.eql(u8, tgt, client.nickname())) {
                        // If the target is us, it likely has our
                        // hostname in it.
                        const source = msg2.source() orelse return;
                        const n = mem.indexOfScalar(u8, source, '!') orelse source.len;
                        break :blk source[0..n];
                    } else break :blk tgt;
                };

                // We handle batches separately. When we encounter a
                // PRIVMSG from a batch, we use the original target
                // from the batch start. We also never notify from a
                // batched message. Batched messages also require
                // sorting
                var tag_iter = msg2.tagIterator();
                while (tag_iter.next()) |tag| {
                    if (mem.eql(u8, tag.key, "batch")) {
                        const entry = client.batches.getEntry(tag.value) orelse @panic("TODO");
                        var channel = entry.value_ptr.*;
                        try channel.messages.append(msg2);
                        std.sort.insertion(Message, channel.messages.items, {}, Message.compareTime);
                        channel.at_oldest = false;
                        const time = msg2.time() orelse continue;
                        if (time.unixTimestamp() > channel.last_read) {
                            channel.has_unread = true;
                            const content = iter.next() orelse continue;
                            if (std.mem.indexOf(u8, content, client.nickname())) |_| {
                                channel.has_unread_highlight = true;
                            }
                        }
                        break;
                    }
                } else {
                    // standard handling
                    var channel = try client.getOrCreateChannel(target);
                    try channel.messages.append(msg2);
                    const content = iter.next() orelse return;
                    var has_highlight = false;
                    {
                        const sender: []const u8 = blk: {
                            const src = msg2.source() orelse break :blk "";
                            const l = std.mem.indexOfScalar(u8, src, '!') orelse
                                std.mem.indexOfScalar(u8, src, '@') orelse
                                src.len;
                            break :blk src[0..l];
                        };
                        try lua.onMessage(self.app.lua, client, channel.name, sender, content);
                    }
                    if (std.mem.indexOf(u8, content, client.nickname())) |_| {
                        var buf: [64]u8 = undefined;
                        const title_or_err = if (msg2.source()) |source|
                            std.fmt.bufPrint(&buf, "{s} - {s}", .{ channel.name, source })
                        else
                            std.fmt.bufPrint(&buf, "{s}", .{channel.name});
                        const title = title_or_err catch title: {
                            const len = @min(buf.len, channel.name.len);
                            @memcpy(buf[0..len], channel.name[0..len]);
                            break :title buf[0..len];
                        };
                        _ = title;
                        // TODO: fix this
                        // try self.vx.notify(writer, title, content);
                        has_highlight = true;
                    }
                    const time = msg2.time() orelse return;
                    if (time.unixTimestamp() > channel.last_read) {
                        channel.has_unread_highlight = has_highlight;
                        channel.has_unread = true;
                    }
                }

                // If we get a message from the current user mark the channel as
                // read, since they must have just sent the message.
                const sender: []const u8 = blk: {
                    const src = msg2.source() orelse break :blk "";
                    const l = std.mem.indexOfScalar(u8, src, '!') orelse
                        std.mem.indexOfScalar(u8, src, '@') orelse
                        src.len;
                    break :blk src[0..l];
                };
                if (std.mem.eql(u8, sender, client.nickname())) {
                    self.app.markSelectedChannelRead();
                }
            },
        }
    }

    pub fn nickname(self: *Client) []const u8 {
        return self.config.network_nick orelse self.config.nick;
    }

    pub fn ack(self: *Client, cap: []const u8) void {
        const info = @typeInfo(Capabilities);
        assert(info == .Struct);

        inline for (info.Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, cap)) {
                @field(self.caps, field.name) = true;
                return;
            }
        }
    }

    pub fn read(self: *Client, buf: []u8) !usize {
        switch (self.config.tls) {
            true => return self.client.read(buf),
            false => return self.stream.read(buf),
        }
    }

    pub fn readLoop(self: *Client) !void {
        var delay: u64 = 1 * std.time.ns_per_s;

        while (!self.should_close) {
            self.status = .disconnected;
            log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
            self.connect() catch |err| {
                log.err("connection error: {}", .{err});
                self.status = .disconnected;
                log.debug("disconnected", .{});
                log.debug("reconnecting in {d} seconds...", .{@divFloor(delay, std.time.ns_per_s)});
                std.time.sleep(delay);
                delay = delay * 2;
                if (delay > std.time.ns_per_min) delay = std.time.ns_per_min;
                continue;
            };
            log.debug("connected", .{});
            self.status = .connected;
            delay = 1 * std.time.ns_per_s;

            var buf: [16_384]u8 = undefined;

            // 4x max size. We will almost always be *way* under our maximum size, so we will have a
            // lot more potential messages than just 4
            var pool: MessagePool = .{};
            pool.init();

            errdefer |err| {
                log.err("client: {s} error: {}", .{ self.config.network_id.?, err });
            }

            const timeout = std.mem.toBytes(std.posix.timeval{
                .tv_sec = 5,
                .tv_usec = 0,
            });

            const keep_alive: i64 = 10 * std.time.ms_per_s;
            // max round trip time equal to our timeout
            const max_rt: i64 = 5 * std.time.ms_per_s;
            var last_msg: i64 = std.time.milliTimestamp();
            var start: usize = 0;

            while (true) {
                try std.posix.setsockopt(
                    self.stream.handle,
                    std.posix.SOL.SOCKET,
                    std.posix.SO.RCVTIMEO,
                    &timeout,
                );
                const n = self.read(buf[start..]) catch |err| {
                    if (err != error.WouldBlock) break;
                    const now = std.time.milliTimestamp();
                    if (now - last_msg > keep_alive + max_rt) {
                        // reconnect??
                        self.status = .disconnected;
                        self.redraw.store(true, .unordered);
                        break;
                    }
                    if (now - last_msg > keep_alive) {
                        // send a ping
                        try self.queueWrite("PING comlink\r\n");
                        continue;
                    }
                    continue;
                };
                if (self.should_close) return;
                if (n == 0) {
                    self.status = .disconnected;
                    self.redraw.store(true, .unordered);
                    break;
                }
                last_msg = std.time.milliTimestamp();
                var i: usize = 0;
                while (std.mem.indexOfPos(u8, buf[0 .. n + start], i, "\r\n")) |idx| {
                    defer i = idx + 2;
                    const buffer = pool.alloc(idx - i);
                    // const line = try self.alloc.dupe(u8, buf[i..idx]);
                    @memcpy(buffer.slice(), buf[i..idx]);
                    assert(std.mem.eql(u8, buf[idx .. idx + 2], "\r\n"));
                    log.debug("[<-{s}] {s}", .{ self.config.name orelse self.config.server, buffer.slice() });
                    try self.fifo.writeItem(.{ .client = self, .msg = buffer });
                }
                if (i != n) {
                    // we had a part of a line read. Copy it to the beginning of the
                    // buffer
                    std.mem.copyForwards(u8, buf[0 .. (n + start) - i], buf[i..(n + start)]);
                    start = (n + start) - i;
                } else start = 0;
            }
        }
    }

    pub fn print(self: *Client, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        self.write_queue.push(.{ .write = .{
            .client = self,
            .msg = msg,
        } });
    }

    /// push a write request into the queue. The request should include the trailing
    /// '\r\n'. queueWrite will dupe the message and free after processing.
    pub fn queueWrite(self: *Client, msg: []const u8) Allocator.Error!void {
        self.write_queue.push(.{ .write = .{
            .client = self,
            .msg = try self.alloc.dupe(u8, msg),
        } });
    }

    pub fn write(self: *Client, buf: []const u8) !void {
        log.debug("[->{s}] {s}", .{ self.config.name orelse self.config.server, buf[0 .. buf.len - 2] });
        switch (self.config.tls) {
            true => try self.client.writeAll(buf),
            false => try self.stream.writeAll(buf),
        }
    }

    pub fn connect(self: *Client) !void {
        if (self.config.tls) {
            const port: u16 = self.config.port orelse 6697;
            self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, port);
            self.client = try tls.client(self.stream, .{
                .host = self.config.server,
                .root_ca = self.app.bundle,
            });
        } else {
            const port: u16 = self.config.port orelse 6667;
            self.stream = try std.net.tcpConnectToHost(self.alloc, self.config.server, port);
        }

        try self.queueWrite("CAP LS 302\r\n");

        const cap_names = std.meta.fieldNames(Capabilities);
        for (cap_names) |cap| {
            try self.print(
                "CAP REQ :{s}\r\n",
                .{cap},
            );
        }

        try self.print(
            "NICK {s}\r\n",
            .{self.config.nick},
        );

        try self.print(
            "USER {s} 0 * {s}\r\n",
            .{ self.config.user, self.config.real_name },
        );
    }

    pub fn getOrCreateChannel(self: *Client, name: []const u8) Allocator.Error!*Channel {
        for (self.channels.items) |channel| {
            if (caseFold(name, channel.name)) return channel;
        }
        const channel = try self.alloc.create(Channel);
        try channel.init(self.alloc, self, name, self.app.unicode);
        try self.channels.append(channel);

        std.sort.insertion(*Channel, self.channels.items, {}, Channel.compare);
        return channel;
    }

    var color_indices = [_]u8{ 1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14 };

    pub fn getOrCreateUser(self: *Client, nick: []const u8) Allocator.Error!*User {
        return self.users.get(nick) orelse {
            const color_u32 = std.hash.Fnv1a_32.hash(nick);
            const index = color_u32 % color_indices.len;
            const color_index = color_indices[index];

            const color: vaxis.Color = .{
                .index = color_index,
            };
            const user = try self.alloc.create(User);
            user.* = .{
                .nick = try self.alloc.dupe(u8, nick),
                .color = color,
            };
            try self.users.put(user.nick, user);
            return user;
        };
    }

    pub fn whox(self: *Client, channel: *Channel) !void {
        channel.who_requested = true;
        if (channel.name.len > 0 and
            channel.name[0] != '#')
        {
            const other = try self.getOrCreateUser(channel.name);
            const me = try self.getOrCreateUser(self.config.nick);
            try channel.addMember(other, .{});
            try channel.addMember(me, .{});
            return;
        }
        // Only use WHO if we have WHOX and away-notify. Without
        // WHOX, we can get rate limited on eg. libera. Without
        // away-notify, our list will become stale
        if (self.supports.whox and
            self.caps.@"away-notify" and
            !channel.in_flight.who)
        {
            channel.in_flight.who = true;
            try self.print(
                "WHO {s} %cnfr\r\n",
                .{channel.name},
            );
        } else {
            channel.in_flight.names = true;
            try self.print(
                "NAMES {s}\r\n",
                .{channel.name},
            );
        }
    }

    /// fetch the history for the provided channel.
    pub fn requestHistory(self: *Client, cmd: ChatHistoryCommand, channel: *Channel) !void {
        if (!self.caps.@"draft/chathistory") return;
        if (channel.history_requested) return;

        channel.history_requested = true;

        if (channel.messages.items.len == 0) {
            try self.print(
                "CHATHISTORY LATEST {s} * 50\r\n",
                .{channel.name},
            );
            channel.history_requested = true;
            return;
        }

        switch (cmd) {
            .before => {
                assert(channel.messages.items.len > 0);
                const first = channel.messages.items[0];
                const time = first.getTag("time") orelse
                    return error.NoTimeTag;
                try self.print(
                    "CHATHISTORY BEFORE {s} timestamp={s} 50\r\n",
                    .{ channel.name, time },
                );
                channel.history_requested = true;
            },
            .after => {
                assert(channel.messages.items.len > 0);
                const last = channel.messages.getLast();
                const time = last.getTag("time") orelse
                    return error.NoTimeTag;
                try self.print(
                    // we request 500 because we have no
                    // idea how long we've been offline
                    "CHATHISTORY AFTER {s} timestamp={s} 500\r\n",
                    .{ channel.name, time },
                );
                channel.history_requested = true;
            },
        }
    }
};

pub fn toVaxisColor(irc: u8) vaxis.Color {
    return switch (irc) {
        0 => .default, // white
        1 => .{ .index = 0 }, // black
        2 => .{ .index = 4 }, // blue
        3 => .{ .index = 2 }, // green
        4 => .{ .index = 1 }, // red
        5 => .{ .index = 3 }, // brown
        6 => .{ .index = 5 }, // magenta
        7 => .{ .index = 11 }, // orange
        8 => .{ .index = 11 }, // yellow
        9 => .{ .index = 10 }, // light green
        10 => .{ .index = 6 }, // cyan
        11 => .{ .index = 14 }, // light cyan
        12 => .{ .index = 12 }, // light blue
        13 => .{ .index = 13 }, // pink
        14 => .{ .index = 8 }, // grey
        15 => .{ .index = 7 }, // light grey

        // 16 to 98 are specifically defined
        16 => .{ .index = 52 },
        17 => .{ .index = 94 },
        18 => .{ .index = 100 },
        19 => .{ .index = 58 },
        20 => .{ .index = 22 },
        21 => .{ .index = 29 },
        22 => .{ .index = 23 },
        23 => .{ .index = 24 },
        24 => .{ .index = 17 },
        25 => .{ .index = 54 },
        26 => .{ .index = 53 },
        27 => .{ .index = 89 },
        28 => .{ .index = 88 },
        29 => .{ .index = 130 },
        30 => .{ .index = 142 },
        31 => .{ .index = 64 },
        32 => .{ .index = 28 },
        33 => .{ .index = 35 },
        34 => .{ .index = 30 },
        35 => .{ .index = 25 },
        36 => .{ .index = 18 },
        37 => .{ .index = 91 },
        38 => .{ .index = 90 },
        39 => .{ .index = 125 },
        // TODO: finish these out https://modern.ircdocs.horse/formatting#color

        99 => .default,

        else => .{ .index = irc },
    };
}

const CaseMapAlgo = enum {
    ascii,
    rfc1459,
    rfc1459_strict,
};

pub fn caseMap(char: u8, algo: CaseMapAlgo) u8 {
    switch (algo) {
        .ascii => {
            switch (char) {
                'A'...'Z' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459 => {
            switch (char) {
                'A'...'^' => return char + 0x20,
                else => return char,
            }
        },
        .rfc1459_strict => {
            switch (char) {
                'A'...']' => return char + 0x20,
                else => return char,
            }
        },
    }
}

pub fn caseFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var i: usize = 0;
    while (i < a.len) {
        const diff = std.mem.indexOfDiff(u8, a[i..], b[i..]) orelse return true;
        const a_diff = caseMap(a[diff], .rfc1459);
        const b_diff = caseMap(b[diff], .rfc1459);
        if (a_diff != b_diff) return false;
        i += diff + 1;
    }
    return true;
}

pub const ChatHistoryCommand = enum {
    before,
    after,
};

test "caseFold" {
    try testing.expect(caseFold("a", "A"));
    try testing.expect(caseFold("aBcDeFgH", "abcdefgh"));
}

test "simple message" {
    const msg: Message = .{ .bytes = "JOIN" };
    try testing.expect(msg.command() == .JOIN);
}

test "simple message with extra whitespace" {
    const msg: Message = .{ .bytes = "JOIN      " };
    try testing.expect(msg.command() == .JOIN);
}

test "well formed message with tags, source, params" {
    const msg: Message = .{ .bytes = "@key=value :example.chat JOIN abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
}

test "message with tags, source, params and extra whitespace" {
    const msg: Message = .{ .bytes = "@key=value        :example.chat        JOIN    abc def" };

    var tag_iter = msg.tagIterator();
    const tag = tag_iter.next();
    try testing.expect(tag != null);
    try testing.expectEqualStrings("key", tag.?.key);
    try testing.expectEqualStrings("value", tag.?.value);
    try testing.expect(tag_iter.next() == null);

    const source = msg.source();
    try testing.expect(source != null);
    try testing.expectEqualStrings("example.chat", source.?);
    try testing.expect(msg.command() == .JOIN);

    var param_iter = msg.paramIterator();
    const p1 = param_iter.next();
    const p2 = param_iter.next();
    try testing.expect(p1 != null);
    try testing.expect(p2 != null);
    try testing.expectEqualStrings("abc", p1.?);
    try testing.expectEqualStrings("def", p2.?);

    try testing.expect(param_iter.next() == null);
}

test "param iterator: simple list" {
    var iter: Message.ParamIterator = .{ .params = "a b c" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("a", param),
            1 => try testing.expectEqualStrings("b", param),
            2 => try testing.expectEqualStrings("c", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: trailing colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS :sasl multi-prefix" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings("sasl multi-prefix", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}

test "param iterator: colon and leading colon" {
    var iter: Message.ParamIterator = .{ .params = "* LS ::)" };
    var i: usize = 0;
    while (iter.next()) |param| {
        switch (i) {
            0 => try testing.expectEqualStrings("*", param),
            1 => try testing.expectEqualStrings("LS", param),
            2 => try testing.expectEqualStrings(":)", param),
            else => return error.TooManyParams,
        }
        i += 1;
    }
    try testing.expect(i == 3);
}
