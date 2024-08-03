const std = @import("std");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const irc = comlink.irc;
const App = comlink.App;
const EventLoop = comlink.EventLoop;
const Lua = ziglua.Lua;

const assert = std.debug.assert;

/// lua constant for the REGISTRYINDEX table
const registry_index = ziglua.registry_index;

/// global key for the app userdata pointer in the registry
const app_key = "comlink.app";

/// global key for the loop userdata pointer
const loop_key = "comlink.loop";

/// active client key. This gets replaced with the client context during callbacks
const client_key = "comlink.client";

pub fn init(app: *App, lua: *Lua, loop: *comlink.EventLoop) !void {
    // load standard libraries
    lua.openLibs();

    // preload our library
    _ = try lua.getGlobal("package"); // [package]
    _ = lua.getField(-1, "preload"); // [package, preload]
    lua.pushFunction(ziglua.wrap(Comlink.preloader)); // [package, preload, function]
    lua.setField(-2, "comlink"); // [package, preload]
    // empty the stack
    lua.pop(2); // []

    // keep a reference to our app in the lua state
    lua.pushLightUserdata(app); // [userdata]
    lua.setField(registry_index, app_key); // []
    // keep a reference to our loop in the lua state
    lua.pushLightUserdata(loop); // [userdata]
    lua.setField(registry_index, loop_key); // []

    // load config
    const home = app.env.get("HOME") orelse return error.EnvironmentVariableNotFound;
    var buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/.config/comlink/init.lua", .{home});
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
    // as lightuserdata
    return app;
}

/// retrieves the *Loop lightuserdata from the registry index
fn getLoop(lua: *Lua) *EventLoop {
    const lua_type = lua.getField(registry_index, loop_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const loop = lua.toUserdata(comlink.EventLoop, -1) catch unreachable; // already asserted
    // as lightuserdata
    return loop;
}

fn getClient(lua: *Lua) *irc.Client {
    const lua_type = lua.getField(registry_index, client_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const client = lua.toUserdata(irc.Client, -1) catch unreachable; // already asserted
    // as lightuserdata
    return client;
}

/// The on_connect event is emitted when we complete registration and receive a RPL_WELCOME message
pub fn onConnect(lua: *Lua, client: *irc.Client) !void {
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

/// Comlink function namespace
const Comlink = struct {
    /// loads our "comlink" library
    pub fn preloader(lua: *Lua) i32 {
        const fns = [_]ziglua.FnReg{
            .{ .name = "bind", .func = ziglua.wrap(bind) },
            .{ .name = "connect", .func = ziglua.wrap(connect) },
            .{ .name = "log", .func = ziglua.wrap(log) },
            .{ .name = "notify", .func = ziglua.wrap(notify) },
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
        lua.argCheck(lua.isString(2) or lua.isNil(2), 2, "expected a string or nil");

        // [string string?]
        const key_str = lua.toString(1) catch unreachable; // [string?]
        const action = if (lua.isNil(2))
            null
        else
            lua.toString(2) catch unreachable; // []

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
        const command = if (action) |act| std.meta.stringToEnum(comlink.Command, act) orelse {
            // var buf: [64]u8 = undefined;
            // const msg = std.fmt.bufPrintZ(&buf, "{s}", .{"not a valid command: %s"}) catch unreachable;
            // lua.raiseErrorStr(msg, .{action});
            // TODO: go back to raise error str when the null terminator is fixed
            lua.raiseError();
        } else null;

        if (codepoint) |cp| {
            if (command) |cmd| {
                // TODO: check that no existing bind with the same key sequence
                // already exists
                app.binds.append(.{
                    .key = .{
                        .codepoint = cp,
                        .mods = mods,
                    },
                    .command = cmd,
                }) catch lua.raiseError();
            } else {
                for (app.binds.items, 0..) |item, i| {
                    if (item.key.matches(cp, mods)) {
                        _ = app.binds.swapRemove(i);
                        break;
                    }
                }
            }
            // TODO: go back to raise error str when the null terminator is fixed
        }
        return 0;
    }

    /// connects to a client. Accepts a table
    fn connect(lua: *Lua) i32 {
        lua.argCheck(lua.isTable(1), 1, "expected a table");

        // [table]
        var lua_type = lua.getField(1, "user"); // [table,string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'user'");
        const user = lua.toString(-1) catch unreachable; // [table]

        lua_type = lua.getField(1, "nick"); // [table,string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'nick'");
        const nick = lua.toString(-1) catch unreachable; // [table]

        lua_type = lua.getField(1, "password"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'password'");
        const password = lua.toString(-1) catch unreachable; // [table]

        lua_type = lua.getField(1, "real_name"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'real_name'");
        const real_name = lua.toString(-1) catch unreachable; // [table]

        lua_type = lua.getField(1, "server"); // [table, string]
        lua.argCheck(lua_type == .string, 1, "expected a string for field 'server'");
        const server = lua.toString(-1) catch unreachable; // [table]

        lua_type = lua.getField(1, "tls"); // [table, boolean|nil]
        const tls: bool = switch (lua_type) {
            .nil => blk: {
                lua.pop(1); // [table]
                break :blk true;
            },
            .boolean => lua.toBoolean(-1), // [table]
            else => lua.raiseErrorStr("expected a boolean for field 'tls'", .{}),
        };

        lua.pop(1); // []

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
        };

        const loop = getLoop(lua); // []
        loop.postEvent(.{ .connect = cfg });

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
        const title = lua.toString(1) catch { // [string, string]
            lua.raiseErrorStr("couldn't write notification", .{});
        };
        const body = lua.toString(2) catch { // [string, string]
            lua.raiseErrorStr("couldn't write notification", .{});
        };
        lua.pop(2); // []
        app.vx.notify(app.tty.anyWriter(), title, body) catch
            lua.raiseErrorStr("couldn't write notification", .{});
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
