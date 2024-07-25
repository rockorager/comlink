const std = @import("std");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const irc = comlink.irc;
const App = comlink.App;
const Client = irc.Client;
const EventLoop = comlink.EventLoop;
const Lua = ziglua.Lua;

const assert = std.debug.assert;

/// lua constant for the REGISTRYINDEX table
const registry_index = ziglua.registry_index;

/// global key for the app userdata pointer in the registry
const app_key = "comlink.app";

/// global key for the loop userdata pointer
const loop_key = "comlink.loop";

pub fn init(app: *App, loop: *comlink.EventLoop) !void {
    var lua = app.lua;
    // load standard libraries
    lua.openLibs();

    // preload our library
    _ = try lua.getGlobal("package"); // [package]
    _ = lua.getField(-1, "preload"); // [package, preload]
    lua.pushFunction(ziglua.wrap(preloader)); // [package, preload, function]
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

pub fn clearLoop(lua: *Lua) void {
    lua.pushNil();
    lua.setField(registry_index, loop_key);
}

/// loads our "comlink" library
pub fn preloader(lua: *Lua) i32 {
    const fns = [_]ziglua.FnReg{
        .{ .name = "bind", .func = ziglua.wrap(bind) },
        .{ .name = "connect", .func = ziglua.wrap(connect) },
        .{ .name = "log", .func = ziglua.wrap(log) },
    };
    lua.newLibTable(&fns); // [table]
    lua.setFuncs(&fns, 0); // [table]
    return 1;
}

fn log(lua: *Lua) i32 {
    lua.argCheck(lua.isString(1), 1, "expected a string");
    // [string]
    const msg = lua.toString(1) catch unreachable; // []
    std.log.scoped(.lua).info("{s}", .{msg});
    return 0;
}

/// connects to a client. Accepts a table
fn connect(lua: *Lua) i32 {
    lua.argCheck(lua.isTable(1), 1, "expected a table");

    // [table]
    var lua_type = lua.getField(1, "user"); // [table,string]
    lua.argCheck(lua_type == .string, 1, "expected a string for field 'user'");
    const user = lua.toString(-1) catch unreachable; // [table]

    lua_type = lua.getField(1, "nick");
    lua.argCheck(lua_type == .string, 1, "expected a string for field 'nick'");
    const nick = lua.toString(-1) catch unreachable;

    lua_type = lua.getField(1, "password");
    lua.argCheck(lua_type == .string, 1, "expected a string for field 'password'");
    const password = lua.toString(-1) catch unreachable;

    lua_type = lua.getField(1, "real_name");
    lua.argCheck(lua_type == .string, 1, "expected a string for field 'real_name'");
    const real_name = lua.toString(-1) catch unreachable;

    lua_type = lua.getField(1, "server");
    lua.argCheck(lua_type == .string, 1, "expected a string for field 'server'");
    const server = lua.toString(-1) catch unreachable;

    lua_type = lua.getField(1, "tls");
    const tls: bool = switch (lua_type) {
        .nil => true,
        .boolean => lua.toBoolean(-1),
        else => lua.raiseErrorStr("expected a boolean for field 'tls'", .{}),
    };

    const cfg: Client.Config = .{
        .server = server,
        .user = user,
        .nick = nick,
        .password = password,
        .real_name = real_name,
        .tls = tls,
    };

    const loop = getLoop(lua);
    loop.postEvent(.{ .connect = cfg });
    return 0;
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
        var buf: [256]u8 = undefined;
        const act_truncated = if (act.len > 200) act[0..200] else act;
        const msg = std.fmt.bufPrintZ(&buf, "invalid command: '{s}'", .{act_truncated}) catch unreachable;
        lua.raiseErrorStr(msg, .{});
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

/// retrieves the *App lightuserdata from the registry index
fn getApp(lua: *Lua) *App {
    const lua_type = lua.getField(ziglua.registry_index, app_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const app = lua.toUserdata(App, -1) catch unreachable; // already asserted
    // as lightuserdata
    return app;
}

/// retrieves the *Loop lightuserdata from the registry index
fn getLoop(lua: *Lua) *EventLoop {
    const lua_type = lua.getField(ziglua.registry_index, loop_key); // [userdata]
    assert(lua_type == .light_userdata); // set by comlink as a lightuserdata
    const loop = lua.toUserdata(comlink.EventLoop, -1) catch unreachable; // already asserted
    // as lightuserdata
    return loop;
}
