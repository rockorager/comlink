const std = @import("std");
const assert = std.debug.assert;
const ziglua = @import("ziglua");

const App = @import("App.zig");
const Client = @import("Client.zig");
const Lua = ziglua.Lua;

/// lua constant for the REGISTRYINDEX table
pub const registry_index = ziglua.registry_index;

/// global key for the app userdata pointer in the registry
pub const app_key = "zirconium.app";

/// loads our "zirconium" library
pub fn preloader(lua: *Lua) i32 {
    const fns = [_]ziglua.FnReg{
        .{ .name = "connect", .func = ziglua.wrap(connect) },
    };
    lua.newLib(&fns); // [table]
    return 1;
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

/// retrieves the *App lightuserdata from the registry index
fn getApp(lua: *Lua) *App {
    const lua_type = lua.getField(ziglua.registry_index, app_key); // [userdata]
    assert(lua_type == .light_userdata); // set by zirconium as a lightuserdata
    const app = lua.toUserdata(App, -1) catch unreachable; // already asserted
    // as lightuserdata
    return app;
}
