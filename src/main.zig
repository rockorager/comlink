const std = @import("std");
const App = @import("App.zig");

const log = std.log.scoped(.main);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var app = try App.init(alloc);
    defer app.deinit();

    app.run() catch |err| {
        switch (err) {
            // ziglua errors
            error.LuaError => {
                const msg = app.lua.toString(-1) catch "";
                const duped = app.alloc.dupe(u8, std.mem.span(msg)) catch "";
                defer app.alloc.free(duped);
                app.deinit();
                log.err("{s}", .{duped});
                return err;
            },
            else => {},
        }
    };
}

test {
    _ = @import("irc.zig");
}