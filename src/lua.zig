const std = @import("std");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const irc = comlink.irc;
const App = comlink.App;
const Lua = ziglua.Lua;

const assert = std.debug.assert;

/// lua constant for the REGISTRYINDEX table
const registry_index = ziglua.registry_index;

/// global key for the app userdata pointer in the registry
const app_key = "comlink.app";

/// active client key. This gets replaced with the client context during callbacks
const client_key = "comlink.client";

pub fn init(app: *App) !void {
    const lua = app.lua;
    // load standard libraries
    lua.openLibs();

    _ = try lua.getGlobal("package"); // [package]
    _ = lua.getField(1, "preload"); // [package, preload]
    lua.pushFunction(ziglua.wrap(Comlink.preloader)); // [package, preload, function]
    lua.setField(2, "comlink"); // [package, preload]
    lua.pop(1); // [package]
    _ = lua.getField(1, "path"); // [package, string]
    const package_path = try lua.toString(2);
    lua.pop(1); // [package]

    // set package.path
    {
        var buf: [std.posix.PATH_MAX]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const alloc = fba.allocator();
        const prefix = blk: {
            if (app.env.get("XDG_CONFIG_HOME")) |cfg|
                break :blk try std.fs.path.join(alloc, &.{ cfg, "comlink" });
            if (app.env.get("HOME")) |home|
                break :blk try std.fs.path.join(alloc, &.{ home, ".config/comlink" });
            return error.NoConfigFile;
        };
        const base = try std.fs.path.join(app.alloc, &.{ prefix, "?.lua" });
        defer app.alloc.free(base);
        const one = try std.fs.path.join(app.alloc, &.{ prefix, "lua/?.lua" });
        defer app.alloc.free(one);
        const two = try std.fs.path.join(app.alloc, &.{ prefix, "lua/?/init.lua" });
        defer app.alloc.free(two);
        const new_pkg_path = try std.mem.join(app.alloc, ";", &.{ package_path, base, one, two });
        _ = lua.pushString(new_pkg_path); // [package, string]
        lua.setField(1, "path"); // [package];
        defer app.alloc.free(new_pkg_path);
    }

    // empty the stack
    lua.pop(1); // []

    // keep a reference to our app in the lua state
    lua.pushLightUserdata(app); // [userdata]
    lua.setField(registry_index, app_key); // []

    // load config
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();
    const path = blk: {
        if (app.env.get("XDG_CONFIG_HOME")) |cfg|
            break :blk try std.fs.path.joinZ(alloc, &.{ cfg, "comlink/init.lua" });
        if (app.env.get("HOME")) |home|
            break :blk try std.fs.path.joinZ(alloc, &.{ home, ".config/comlink/init.lua" });
        unreachable;
    };

    switch (ziglua.lang) {
        .luajit, .lua51 => lua.loadFile(path) catch return error.LuaError,
        else => lua.loadFile(path, .binary_text) catch return error.LuaError,
    }
    lua.protectedCall(0, ziglua.mult_return, 0) catch return error.LuaError;
}

/// retrieves the *App lightuserdata from the registry index
fn getApp(lua: *Lua) *App {
    const lua_type = lua.getField(registry_index, app_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const app = lua.toUserdata(App, -1) catch unreachable; // already asserted
    lua.pop(1); // []
    // as lightuserdata
    return app;
}

// /// retrieves the *Loop lightuserdata from the registry index
// fn getLoop(lua: *Lua) *EventLoop {
//     const lua_type = lua.getField(registry_index, loop_key); // [userdata]
//     assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
//     const loop = lua.toUserdata(comlink.EventLoop, -1) catch unreachable; // already asserted
//     // as lightuserdata
//     return loop;
// }

fn getClient(lua: *Lua) *irc.Client {
    const lua_type = lua.getField(registry_index, client_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const client = lua.toUserdata(irc.Client, -1) catch unreachable; // already asserted
    // as lightuserdata
    return client;
}

/// The on_connect event is emitted when we complete registration and receive a RPL_WELCOME message
pub fn onConnect(lua: *Lua, client: *irc.Client) !void {
    defer lua.setTop(0); // []
    lua.pushLightUserdata(client); // [light_userdata]
    lua.setField(registry_index, client_key); // []

    Client.getTable(lua, client.config.lua_table); // [table]
    const lua_type = lua.getField(1, "on_connect"); // [table, type]
    switch (lua_type) {
        .function => {
            // Push the table to the top since it is our argument to the function
            lua.pushValue(1); // [table, function, table]
            lua.protectedCall(1, 0, 0) catch return error.LuaError; // [table]
            // clear the stack
            lua.pop(1); // []
        },
        else => {},
    }
}

pub fn onMessage(lua: *Lua, client: *irc.Client, channel: []const u8, sender: []const u8, msg: []const u8) !void {
    defer lua.setTop(0); // []
    Client.getTable(lua, client.config.lua_table); // [table]
    const lua_type = lua.getField(1, "on_message"); // [table, type]
    switch (lua_type) {
        .function => {
            // Push the table to the top since it is our argument to the function
            _ = lua.pushString(channel); // [function,string]
            _ = lua.pushString(sender); // [function,string,string]
            _ = lua.pushString(msg); // [function,string,string,string]
            lua.protectedCall(3, 0, 0) catch return error.LuaError;
        },
        else => {},
    }
}

pub fn execFn(lua: *Lua, func: i32) !void {
    const lua_type = lua.rawGetIndex(registry_index, func); // [function]
    switch (lua_type) {
        .function => lua.protectedCall(0, 0, 0) catch return error.LuaError,
        else => lua.raiseErrorStr("not a function", .{}),
    }
}

pub fn execUserCommand(lua: *Lua, cmdline: []const u8, func: i32) !void {
    defer lua.setTop(0); // []
    const lua_type = lua.rawGetIndex(registry_index, func); // [function]
    _ = lua.pushString(cmdline); // [function, string]

    switch (lua_type) {
        .function => lua.protectedCall(1, 0, 0) catch |err| {
            const msg = lua.toString(-1) catch {
                std.log.err("{}", .{err});
                return error.LuaError;
            };
            std.log.err("{s}", .{msg});
        },
        else => lua.raiseErrorStr("not a function", .{}),
    }
}

/// Comlink function namespace
const Comlink = struct {
    /// loads our "comlink" library
    pub fn preloader(lua: *Lua) i32 {
        const fns = [_]ziglua.FnReg{
            .{ .name = "bind", .func = ziglua.wrap(bind) },
            .{ .name = "connect", .func = ziglua.wrap(connect) },
            .{ .name = "log", .func = ziglua.wrap(log) },
            .{ .name = "notify", .func = ziglua.wrap(notify) },
            .{ .name = "add_command", .func = ziglua.wrap(addCommand) },
            .{ .name = "selected_channel", .func = ziglua.wrap(Comlink.selectedChannel) },
        };
        lua.newLibTable(&fns); // [table]
        lua.setFuncs(&fns, 0); // [table]
        return 1;
    }

    /// creates a keybind. Accepts one or two string.
    ///
    /// The first string is the key binding. The second string is the optional
    /// action. If nil, the key is unbound (if a binding exists). Otherwise, the
    /// provided key is bound to the provided action.
    fn bind(lua: *Lua) i32 {
        const app = getApp(lua);
        lua.argCheck(lua.isString(1), 1, "expected a string");
        lua.argCheck(lua.isString(2) or lua.isNil(2) or lua.isFunction(2), 2, "expected a string, a function, or nil");

        // [string {string,function,nil}]
        const key_str = lua.toString(1) catch unreachable;

        var codepoint: ?u21 = null;
        var mods: vaxis.Key.Modifiers = .{};

        var iter = std.mem.splitScalar(u8, key_str, '+');
        while (iter.next()) |key_txt| {
            const last = iter.peek() == null;
            if (last) {
                codepoint = vaxis.Key.name_map.get(key_txt) orelse
                    std.unicode.utf8Decode(key_txt) catch {
                    lua.raiseErrorStr("invalid utf8 or more than one codepoint", .{});
                };
            }
            if (std.mem.eql(u8, "shift", key_txt))
                mods.shift = true
            else if (std.mem.eql(u8, "alt", key_txt))
                mods.alt = true
            else if (std.mem.eql(u8, "ctrl", key_txt))
                mods.ctrl = true
            else if (std.mem.eql(u8, "super", key_txt))
                mods.super = true
            else if (std.mem.eql(u8, "hyper", key_txt))
                mods.hyper = true
            else if (std.mem.eql(u8, "meta", key_txt))
                mods.meta = true;
        }

        const cp = codepoint orelse lua.raiseErrorStr("invalid keybind", .{});

        const cmd: comlink.Command = switch (lua.typeOf(2)) {
            .string => blk: {
                const cmd_str = lua.toString(2) catch unreachable;
                const cmd = comlink.Command.fromString(cmd_str) orelse
                    lua.raiseErrorStr("unknown command", .{});
                break :blk cmd;
            },
            .function => blk: {
                const ref = lua.ref(registry_index) catch
                    lua.raiseErrorStr("couldn't ref keybind function", .{});
                const cmd: comlink.Command = .{ .lua_function = ref };
                break :blk cmd;
            },
            .nil => {
                // remove the keybind
                for (app.binds.items, 0..) |item, i| {
                    if (item.key.matches(cp, mods)) {
                        _ = app.binds.swapRemove(i);
                        break;
                    }
                }
                return 0;
            },
            else => unreachable,
        };

        // replace an existing bind if we have one
        for (app.binds.items) |*item| {
            if (item.key.matches(cp, mods)) {
                item.command = cmd;
                break;
            }
        } else {
            // otherwise add a new bind
            app.binds.append(.{
                .key = .{ .codepoint = cp, .mods = mods },
                .command = cmd,
            }) catch lua.raiseErrorStr("out of memory", .{});
        }
        return 0;
    }

    /// connects to a client. Accepts a table
    fn connect(lua: *Lua) i32 {
        lua.argCheck(lua.isTable(1), 1, "expected a table");

        // [table]
        var lua_type = lua.getField(1, "user"); // [table,string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'user'");
        const user = lua.toString(-1) catch unreachable;
        lua.pop(1); // [table]

        lua_type = lua.getField(1, "nick"); // [table,string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'nick'");
        const nick = lua.toString(-1) catch unreachable;
        lua.pop(1); // [table]

        lua_type = lua.getField(1, "password"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'password'");
        const password = lua.toString(-1) catch unreachable;
        lua.pop(1); // [table]

        lua_type = lua.getField(1, "real_name"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'real_name'");
        const real_name = lua.toString(-1) catch unreachable;
        lua.pop(1); // [table]

        lua_type = lua.getField(1, "server"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'server'");
        const server = lua.toString(-1) catch unreachable; // [table]
        lua.pop(1); // [table]

        lua_type = lua.getField(1, "tls"); // [table, boolean|nil]
        const tls: bool = switch (lua_type) {
            .nil => blk: {
                lua.pop(1); // [table]
                break :blk true;
            },
            .boolean => blk: {
                const val = lua.toBoolean(-1);
                lua.pop(1); // [table]
                break :blk val;
            },
            else => lua.raiseErrorStr("expected a boolean for field 'tls'", .{}),
        };

        lua_type = lua.getField(1, "port"); // [table, int|nil]
        lua.argCheck(lua_type == .nil or lua_type == .number, 1, "expected a number or nil");
        const port: ?u16 = switch (lua_type) {
            .nil => blk: {
                lua.pop(1); // [table]
                break :blk null;
            },
            .number => blk: {
                const val = lua.toNumber(-1) catch unreachable;
                lua.pop(1); // [table]
                break :blk @intFromFloat(val);
            },
            else => lua.raiseErrorStr("expected a boolean for field 'tls'", .{}),
        };

        // Ref the config table so it doesn't get garbage collected
        _ = lua.ref(registry_index) catch lua.raiseErrorStr("couldn't ref config table", .{}); // []

        Client.initTable(lua); // [table]
        const table_ref = lua.ref(registry_index) catch {
            lua.raiseErrorStr("couldn't ref client table", .{});
        };

        const cfg: irc.Client.Config = .{
            .server = server,
            .user = user,
            .nick = nick,
            .password = password,
            .real_name = real_name,
            .tls = tls,
            .lua_table = table_ref,
            .port = port,
        };

        const app = getApp(lua);
        app.connect(cfg) catch {
            lua.raiseErrorStr("couldn't connect", .{});
        };

        // put the table back on the stack
        Client.getTable(lua, table_ref); // [table]
        return 1; // []
    }

    fn log(lua: *Lua) i32 {
        lua.argCheck(lua.isString(1), 1, "expected a string"); // [string]
        const msg = lua.toString(1) catch unreachable; // []
        std.log.scoped(.lua).info("{s}", .{msg});
        return 0;
    }

    /// System notification. Takes two strings: title, body
    fn notify(lua: *Lua) i32 {
        lua.argCheck(lua.isString(1), 1, "expected a string"); // [string, string]
        lua.argCheck(lua.isString(2), 2, "expected a string"); // [string, string]
        const app = getApp(lua);
        _ = app; // autofix
        const title = lua.toString(1) catch { // [string, string]
            lua.raiseErrorStr("couldn't write notification", .{});
        };
        _ = title; // autofix
        const body = lua.toString(2) catch { // [string, string]
            lua.raiseErrorStr("couldn't write notification", .{});
        };
        _ = body; // autofix
        lua.pop(2); // []
        // app.vx.notify(app.tty.anyWriter(), title, body) catch
        //     lua.raiseErrorStr("couldn't write notification", .{});
        return 0;
    }

    /// Add a user command to the command list
    fn addCommand(lua: *Lua) i32 {
        lua.argCheck(lua.isString(1), 1, "expected a string"); // [string, function]
        lua.argCheck(lua.isFunction(2), 2, "expected a function"); // [string, function]
        const ref = lua.ref(registry_index) catch lua.raiseErrorStr("couldn't ref function", .{}); // [string]
        const cmd = lua.toString(1) catch unreachable;

        // ref the string so we don't garbage collect it
        _ = lua.ref(registry_index) catch lua.raiseErrorStr("couldn't ref command name", .{}); // []
        comlink.Command.user_commands.put(cmd, ref) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }

    fn selectedChannel(lua: *Lua) i32 {
        const app = getApp(lua);
        if (app.selectedBuffer()) |buf| {
            switch (buf) {
                .client => {},
                .channel => |chan| {
                    Channel.initTable(lua, chan); // [table]
                    return 1;
                },
            }
        }
        lua.pushNil(); // [nil]
        return 1;
    }
};

const Channel = struct {
    fn initTable(lua: *Lua, channel: *irc.Channel) void {
        const fns = [_]ziglua.FnReg{
            .{ .name = "send_msg", .func = ziglua.wrap(Channel.sendMsg) },
            .{ .name = "name", .func = ziglua.wrap(Channel.name) },
            .{ .name = "mark_read", .func = ziglua.wrap(Channel.markRead) },
        };
        lua.newLibTable(&fns); // [table]
        lua.setFuncs(&fns, 0); // [table]

        lua.pushLightUserdata(channel); // [table, lightuserdata]
        lua.setField(1, "_ptr"); // [table]
    }

    fn sendMsg(lua: *Lua) i32 {
        lua.argCheck(lua.isTable(1), 1, "expected a table"); // [table]
        lua.argCheck(lua.isString(2), 2, "expected a string"); // [table,string]
        const msg = lua.toString(2) catch unreachable;
        lua.pop(1); // [table]
        const lua_type = lua.getField(1, "_ptr"); // [table, lightuserdata]
        lua.argCheck(lua_type == .light_userdata, 2, "expected lightuserdata");
        const channel = lua.toUserdata(irc.Channel, 2) catch unreachable;
        lua.pop(1); // [table]

        if (msg.len > 0 and msg[0] == '/') {
            const app = getApp(lua);
            app.handleCommand(lua, .{ .channel = channel }, msg) catch
                lua.raiseErrorStr("couldn't handle command", .{});
            return 0;
        }

        var buf: [1024]u8 = undefined;
        const msg_final = std.fmt.bufPrint(
            &buf,
            "PRIVMSG {s} :{s}\r\n",
            .{ channel.name, msg },
        ) catch lua.raiseErrorStr("out of memory", .{});
        channel.client.queueWrite(msg_final) catch lua.raiseErrorStr("out of memory", .{});
        return 0;
    }

    fn name(lua: *Lua) i32 {
        lua.argCheck(lua.isTable(1), 1, "expected a table"); // [table]
        const lua_type = lua.getField(1, "_ptr"); // [table, lightuserdata]
        lua.argCheck(lua_type == .light_userdata, 2, "expected lightuserdata");
        const channel = lua.toUserdata(irc.Channel, 2) catch unreachable;
        lua.pop(2); // []
        _ = lua.pushString(channel.name); // [string]
        return 1;
    }

    fn markRead(lua: *Lua) i32 {
        lua.argCheck(lua.isTable(1), 1, "expected a table"); // [table]
        const lua_type = lua.getField(1, "_ptr"); // [table, lightuserdata]
        lua.argCheck(lua_type == .light_userdata, 2, "expected lightuserdata");
        const channel = lua.toUserdata(irc.Channel, 2) catch unreachable;
        channel.markRead() catch |err| {
            std.log.err("couldn't mark channel as read: {}", .{err});
        };
        lua.pop(2); // []
        return 0;
    }
};

/// Client function namespace
const Client = struct {
    /// initialize a table for a client and pushes it on the stack
    fn initTable(lua: *Lua) void {
        const fns = [_]ziglua.FnReg{
            .{ .name = "join", .func = ziglua.wrap(Client.join) },
            .{ .name = "name", .func = ziglua.wrap(Client.name) },
        };
        lua.newLibTable(&fns); // [table]
        lua.setFuncs(&fns, 0); // [table]

        lua.pushNil(); // [table, nil]
        lua.setField(1, "on_connect"); // [table]
    }

    /// retrieve a client table and push it on the stack
    fn getTable(lua: *Lua, i: i32) void {
        const lua_type = lua.rawGetIndex(registry_index, i); // [table]
        if (lua_type != .table)
            lua.raiseErrorStr("couldn't get client table", .{});
    }

    /// exectute a join command
    fn join(lua: *Lua) i32 {
        const client = getClient(lua);
        lua.argCheck(lua.isString(1), 1, "expected a string"); // [string]
        const channel = lua.toString(1) catch unreachable; // []
        assert(channel.len < 120); // channel name too long
        var buf: [128]u8 = undefined;

        const msg = std.fmt.bufPrint(
            &buf,
            "JOIN {s}\r\n",
            .{channel},
        ) catch lua.raiseErrorStr("channel name too long", .{});

        client.queueWrite(msg) catch lua.raiseErrorStr("couldn't queue write", .{});

        return 0;
    }

    fn name(lua: *Lua) i32 {
        const client = getClient(lua); // []
        _ = lua.pushString(client.config.name orelse ""); // [string]
        return 1; // []
    }
};
