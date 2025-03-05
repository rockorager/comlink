const std = @import("std");
const options = @import("build_options");
const builtin = @import("builtin");
const comlink = @import("comlink.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const Lua = ziglua.Lua;

const log = std.log.scoped(.main);

pub const panic = vaxis.panic_handler;

pub const version = options.version;

/// Called after receiving a terminating signal
fn cleanUp(sig: c_int) callconv(.C) void {
    if (vaxis.tty.global_tty) |gty| {
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

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const gpa, const is_debug = gpa: {
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var args = try std.process.argsWithAllocator(gpa);
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
            std.posix.sigaction(std.posix.SIG.INT, &action, null);
            std.posix.sigaction(std.posix.SIG.TERM, &action, null);
        },
    }

    comlink.Command.user_commands = std.StringHashMap(i32).init(gpa);
    defer comlink.Command.user_commands.deinit();

    var app = try vaxis.vxfw.App.init(gpa);
    defer app.deinit();

    var comlink_app: comlink.App = undefined;
    try comlink_app.init(gpa, &app.vx.unicode);
    defer comlink_app.deinit();

    try app.run(comlink_app.widget(), .{});
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
