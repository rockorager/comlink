const std = @import("std");
const options = @import("build_options");
const builtin = @import("builtin");
const comlink = @import("comlink.zig");
const logger = @import("logger.zig");
const vaxis = @import("vaxis");
const ziglua = @import("ziglua");

const Lua = ziglua.Lua;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .logFn = logger.logFn,
};

pub const panic = vaxis.panic_handler;

pub const version = options.version;

/// Called after receiving a terminating signal
fn cleanUp(sig: std.posix.SIG) callconv(.c) void {
    if (vaxis.tty.global_tty) |*gty| {
        const reset: []const u8 = vaxis.ctlseqs.csi_u_pop ++
            vaxis.ctlseqs.mouse_reset ++
            vaxis.ctlseqs.bp_reset ++
            vaxis.ctlseqs.rmcup;

        const writer = gty.writer();
        writer.writeAll(reset) catch {};
        writer.flush() catch {};

        gty.deinit();
    }
    const sig_int = @intFromEnum(sig);
    if (sig_int < 255)
        std.process.exit(@intCast(sig_int))
    else
        std.process.exit(1);
}

pub fn main(process: std.process.Init) !void {
    const gpa = process.gpa;

    var args = try std.process.Args.Iterator.initAllocator(process.minimal.args, gpa);
    defer args.deinit();
    while (args.next()) |arg| {
        if (argMatch("-v", "--version", arg)) {
            var stdout_buffer: [1024]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(process.io, &stdout_buffer);
            const stdout = &stdout_writer.interface;
            try stdout.print("comlink {s}\n", .{version});
            try stdout.flush();
            return;
        }
    }

    const log_path = try logger.init(gpa, process.io, process.environ_map);
    defer {
        logger.deinit();
        gpa.free(log_path);
    }
    log.info("logging to {s}", .{log_path});

    // Handle termination signals
    switch (builtin.os.tag) {
        .windows => {},
        else => {
            var action: std.posix.Sigaction = .{
                .handler = .{ .handler = cleanUp },
                .mask = switch (builtin.os.tag) {
                    .macos => 0,
                    else => std.posix.sigemptyset(),
                },
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.INT, &action, null);
            std.posix.sigaction(std.posix.SIG.TERM, &action, null);
        },
    }

    comlink.Command.user_commands = std.StringHashMap(i32).init(gpa);
    defer comlink.Command.user_commands.deinit();

    var tty_buffer: [1024]u8 = undefined;
    var app = try vaxis.vxfw.App.init(process.io, gpa, process.environ_map, &tty_buffer);
    defer app.deinit();

    var comlink_app: comlink.App = undefined;
    try comlink_app.init(gpa, process.io, process.environ_map);
    defer comlink_app.deinit();

    try app.run(comlink_app.widget(), .{ .framerate = 30 });
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
    _ = @import("logger.zig");
}
