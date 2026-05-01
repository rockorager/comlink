const std = @import("std");

const Allocator = std.mem.Allocator;

var lock_state: std.atomic.Mutex = .unlocked;
var log_io: ?std.Io = null;
var log_file: ?std.Io.File = null;

pub fn init(alloc: Allocator, io: std.Io, env: *std.process.Environ.Map) ![]u8 {
    const path = try logPath(alloc, env);
    errdefer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        _ = try std.Io.Dir.cwd().createDirPathStatus(io, dir, privateDirPermissions());
    }

    const file = try createLogFile(io, path);
    errdefer file.close(io);
    try seekToEnd(io, file);

    {
        lock();
        defer unlock();

        if (log_file) |old_file| old_file.close(log_io.?);
        log_io = io;
        log_file = file;
    }

    return path;
}

pub fn deinit() void {
    lock();
    defer unlock();

    if (log_file) |file| file.close(log_io.?);
    log_file = null;
    log_io = null;
}

pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    lock();
    if (log_file) |file| {
        const io = log_io.?;
        writeLog(io, file, level, scope, format, args) catch {};
        unlock();
        return;
    }
    unlock();

    std.log.defaultLog(level, scope, format, args);
}

fn writeLog(
    io: std.Io,
    file: std.Io.File,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) !void {
    var buffer: [1024]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    const now_ms = std.Io.Timestamp.now(io, .real).toMilliseconds();

    try writer.interface.print("{d} {s}", .{ now_ms, level.asText() });
    if (scope != .default) try writer.interface.print("({t})", .{scope});
    try writer.interface.writeAll(": ");
    try writer.interface.print(format ++ "\n", args);
    try writer.interface.flush();
}

fn createLogFile(io: std.Io, path: []const u8) !std.Io.File {
    const options: std.Io.Dir.CreateFileOptions = .{
        .truncate = false,
        .permissions = privateFilePermissions(),
    };
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, options);
    }
    return std.Io.Dir.cwd().createFile(io, path, options);
}

fn seekToEnd(io: std.Io, file: std.Io.File) !void {
    const stat = try file.stat(io);
    var buffer: [1]u8 = undefined;
    var writer = file.writerStreaming(io, &buffer);
    try writer.seekTo(stat.size);
}

fn logPath(alloc: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("COMLINK_LOG_FILE")) |path| {
        if (path.len > 0) return alloc.dupe(u8, path);
    }

    const state_home = try stateHome(alloc, env);
    defer alloc.free(state_home);

    return std.fs.path.join(alloc, &.{ state_home, "comlink", "comlink.log" });
}

fn stateHome(alloc: Allocator, env: *std.process.Environ.Map) ![]u8 {
    if (env.get("XDG_STATE_HOME")) |path| {
        if (path.len > 0 and std.fs.path.isAbsolute(path)) {
            return alloc.dupe(u8, path);
        }
    }
    const home = env.get("HOME") orelse return error.NoStateHome;
    if (home.len == 0) return error.NoStateHome;
    return std.fs.path.join(alloc, &.{ home, ".local", "state" });
}

fn privateDirPermissions() std.Io.Dir.Permissions {
    if (@hasDecl(std.Io.Dir.Permissions, "fromMode")) {
        return std.Io.Dir.Permissions.fromMode(0o700);
    }
    return .default_dir;
}

fn privateFilePermissions() std.Io.File.Permissions {
    if (@hasDecl(std.Io.File.Permissions, "fromMode")) {
        return std.Io.File.Permissions.fromMode(0o600);
    }
    return .default_file;
}

fn lock() void {
    while (!lock_state.tryLock()) {
        std.Thread.yield() catch {};
    }
}

fn unlock() void {
    lock_state.unlock();
}

test "stateHome prefers absolute XDG_STATE_HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/tmp/comlink-state");
    try env.put("HOME", "/home/example");

    const path = try stateHome(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/comlink-state", path);
}

test "stateHome ignores relative XDG_STATE_HOME" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "relative-state");
    try env.put("HOME", "/home/example");

    const path = try stateHome(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/home/example/.local/state", path);
}

test "logPath defaults below state home" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_STATE_HOME", "/tmp/comlink-state");

    const path = try logPath(std.testing.allocator, &env);
    defer std.testing.allocator.free(path);

    try std.testing.expectEqualStrings("/tmp/comlink-state/comlink/comlink.log", path);
}
