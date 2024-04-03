const std = @import("std");
const assert = std.debug.assert;
const ziglua = @import("ziglua");

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
        .server = std.mem.span(server),
        .user = std.mem.span(user),
        .nick = std.mem.span(nick),
        .password = std.mem.span(password),
        .real_name = std.mem.span(real_name),
    };
    app.vx.postEvent(.{ .connect = cfg });
    return 0;
}

/// creates a keybind. Accepts a table
fn bind(lua: *Lua) i32 {
    const app = getApp(lua);
    _ = app;
    lua.argCheck(lua.isString(1), 1, "expected a string");
    // second arg can be a string (action) or a lua function
    lua.argCheck(lua.isString(2) or lua.isFunction(2), 1, "expected a string or a function");
}

/// retrieves the *App lightuserdata from the registry index
fn getApp(lua: *Lua) *App {
    const lua_type = lua.getField(ziglua.registry_index, app_key); // [userdata]
    assert(lua_type == .light_userdata); // set by zircon as a lightuserdata
    const app = lua.toUserdata(App, -1) catch unreachable; // already asserted
    // as lightuserdata
    return app;
}
