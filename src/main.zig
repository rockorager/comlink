const std = @import("std");
const options = @import("build_options");
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

pub const version = options.version;

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
        if (builtin.mode == .Debug) {
            const deinit_status = gpa.deinit();
            if (deinit_status == .leak) {
                std.log.err("memory leak", .{});
            }
        }
    }
    const alloc = gpa.allocator();

    var args = try std.process.argsWithAllocator(alloc);
    while (args.next()) |arg| {
        if (argMatch("-v", "--version", arg)) {
            const stdout = std.io.getStdOut();
            try stdout.writer().print("comlink {s}\n", .{version});
            return;
        }
    }

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

    comlink.Command.user_commands = std.StringHashMap(i32).init(alloc);
    defer comlink.Command.user_commands.deinit();

    const lua = try Lua.init(&alloc);
    defer lua.deinit();

    var app = try comlink.App.init(alloc);
    defer app.deinit();

    app.run(lua) catch |err| {
        switch (err) {
            // ziglua errors
            error.LuaError => {
                const msg = lua.toString(-1) catch "";
                const duped = alloc.dupe(u8, msg) catch "";
                app.deinit();
                defer alloc.free(duped);
                log.err("{s}", .{duped});
                return err;
            },
            else => return err,
        }
    };
}

fn argMatch(maybe_short: ?[]const u8, maybe_long: ?[]const u8, arg: [:0]const u8) bool {
    if (maybe_short) |short| {
        if (std.mem.eql(u8, short, arg)) return true;
    }
    if (maybe_long) |long| {
        if (std.mem.eql(u8, long, arg)) return true;
    }
    return false;
}

test {
    _ = @import("format.zig");
    _ = @import("irc.zig");
}
