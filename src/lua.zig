const std = @import("std");
const assert = std.debug.assert;
const ziglua = @import("ziglua");
const vaxis = @import("vaxis");

const App = @import("App.zig");
const irc = @import("irc.zig");
const Client = irc.Client;
const Lua = ziglua.Lua;

/// lua constant for the REGISTRYINDEX table
pub const registry_index = ziglua.registry_index;

/// global key for the app userdata pointer in the registry
pub const app_key = "zircon.app";

/// loads our "zircon" library
pub fn preloader(lua: *Lua) i32 {
    const fns = [_]ziglua.FnReg{
        .{ .name = "bind", .func = ziglua.wrap(bind) },
        .{ .name = "connect", .func = ziglua.wrap(connect) },
        .{ .name = "log", .func = ziglua.wrap(log) },
    };
    lua.newLib(&fns); // [table]
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
    var app = getApp(lua);
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

    const cfg: Client.Config = .{
        .server = server,
        .user = user,
        .nick = nick,
        .password = password,
        .real_name = real_name,
    };
    app.loop.?.postEvent(.{ .connect = cfg });
    return 0;
}

/// creates a keybind. Accepts 2 strings
fn bind(lua: *Lua) i32 {
    const app = getApp(lua);
    lua.argCheck(lua.isString(1), 1, "expected a string");
    lua.argCheck(lua.isString(2), 1, "expected a string");

    // [string string]
    const key_str = lua.toString(1) catch unreachable; // [string]
    const action = lua.toString(2) catch unreachable; // []

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
    const command = std.meta.stringToEnum(App.Command, action) orelse {
        // var buf: [64]u8 = undefined;
        // const msg = std.fmt.bufPrintZ(&buf, "{s}", .{"not a valid command: %s"}) catch unreachable;
        // lua.raiseErrorStr(msg, .{action});
        // TODO: go back to raise error str when the null terminator is fixed
        lua.raiseError();
    };
    if (codepoint) |cp| {
        app.binds.append(.{
            .key = .{
                .codepoint = cp,
                .mods = mods,
            },
            .command = command,
        }) catch lua.raiseError();
        // TODO: go back to raise error str when the null terminator is fixed
    }
    return 0;
}

/// retrieves the *App lightuserdata from the registry index
fn getApp(lua: *Lua) *App {
    const lua_type = lua.getField(ziglua.registry_index, app_key); // [userdata]
    assert(lua_type == .light_userdata); // set by zircon as a lightuserdata
    const app = lua.toUserdata(App, -1) catch unreachable; // already asserted
    // as lightuserdata
    return app;
}
