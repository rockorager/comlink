const std = @import("std");
const builtin = @import("builtin");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const Lua = ziglua.Lua;

const log = std.log.scoped(.main);

pub const panic = vaxis.panic_handler;

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .vaxis, .level = .warn },
        .{ .scope = .vaxis_parser, .level = .warn },
    },
};

/// Called after receiving a terminating signal
fn cleanUp(sig: c_int) callconv(.C) void {
    if (vaxis.Tty.global_tty) |gty| {
        const reset: []const u8 = vaxis.ctlseqs.csi_u_pop ++
            vaxis.ctlseqs.mouse_reset ++
            vaxis.ctlseqs.bp_reset ++
            vaxis.ctlseqs.rmcup;

        gty.anyWriter().writeAll(reset) catch {};

        gty.deinit();
    }
    if (sig < 255 and sig >= 0)
        std.process.exit(@as(u8, @intCast(sig)))
    else
        std.process.exit(1);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const alloc = gpa.allocator();

    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();

    var app = try comlink.App.init(alloc);
    defer app.deinit();

    // Handle termination signals
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            var action: std.posix.Sigaction = .{
                .handler = .{ .handler = cleanUp },
                .mask = switch (builtin.os.tag) {
                    .macos => 0,
                    else => std.posix.empty_sigset,
                },
                .flags = 0,
            };
            try std.posix.sigaction(std.posix.SIG.INT, &action, null);
            try std.posix.sigaction(std.posix.SIG.TERM, &action, null);
        },
    }

    const lua = try Lua.init(&alloc);

    app.run(lua) catch |err| {
        switch (err) {
            // ziglua errors
            error.LuaError => {
                const msg = lua.toString(-1) catch "";
                const duped = alloc.dupe(u8, msg) catch "";
                defer alloc.free(duped);
                log.err("{s}", .{duped});
                return err;
            },
            else => return err,
        }
    };
}

test {
    _ = @import("irc.zig");
}
