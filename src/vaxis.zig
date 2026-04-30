const std = @import("std");
const upstream = @import("vaxis_upstream");

pub const tty = upstream.tty;
pub const Vaxis = upstream.Vaxis;
pub const loop = upstream.loop;
pub const Loop = upstream.Loop;
pub const zigimg = upstream.zigimg;
pub const Queue = upstream.Queue;
pub const Key = upstream.Key;
pub const Cell = upstream.Cell;
pub const Segment = upstream.Segment;
pub const PrintOptions = upstream.PrintOptions;
pub const Style = upstream.Style;
pub const Color = upstream.Color;
pub const Image = upstream.Image;
pub const Mouse = upstream.Mouse;
pub const Screen = upstream.Screen;
pub const AllocatingScreen = upstream.AllocatingScreen;
pub const Parser = upstream.Parser;
pub const Window = upstream.Window;
pub const widgets = upstream.widgets;
pub const gwidth = upstream.gwidth;
pub const ctlseqs = upstream.ctlseqs;
pub const GraphemeCache = upstream.GraphemeCache;
pub const Event = upstream.Event;
pub const unicode = upstream.unicode;

pub const vxfw = @import("vxfw.zig");

pub const Tty = upstream.Tty;
pub const Winsize = upstream.Winsize;

pub fn init(io: std.Io, alloc: std.mem.Allocator, env_map: *std.process.Environ.Map, opts: Vaxis.Options) !Vaxis {
    return upstream.init(io, alloc, env_map, opts);
}

pub const Panic = upstream.Panic;
pub const panic_handler = upstream.panic_handler;
pub const recover = upstream.recover;
pub const log_scopes = upstream.log_scopes;
pub const logo = upstream.logo;
