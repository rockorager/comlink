const std = @import("std");
const vaxis = @import("vaxis");

const vxfw = vaxis.vxfw;

const Allocator = std.mem.Allocator;
const App = @import("app.zig").App;
const ChildList = std.ArrayListUnmanaged(SubSurface);
const Surface = vxfw.Surface;
const SubSurface = vxfw.SubSurface;

const default_rhs: vxfw.Text = .{ .text = "TODO: update this text" };

pub fn drawMain(ptr: *anyopaque, ctx: vxfw.DrawContext) Allocator.Error!Surface {
    const self: *App = @ptrCast(@alignCast(ptr));
    const max = ctx.max.size();
    self.last_height = max.height;
    if (self.selectedBuffer()) |buffer| {
        switch (buffer) {
            .client => |client| self.view.rhs = client.view(),
            .channel => |channel| self.view.rhs = channel.view.widget(),
        }
    } else self.view.rhs = default_rhs.widget();

    var children: ChildList = .empty;

    // UI is a tree of splits
    // │         │                  │         │
    // │         │                  │         │
    // │ buffers │  buffer content  │ members │
    // │         │                  │         │
    // │         │                  │         │
    // │         │                  │         │
    // │         │                  │         │

    const sub: vxfw.SubSurface = .{
        .origin = .{ .col = 0, .row = 0 },
        .surface = try self.view.widget().draw(ctx),
    };
    try children.append(ctx.arena, sub);

    return .{
        .size = ctx.max.size(),
        .widget = self.widget(),
        .buffer = &.{},
        .children = children.items,
    };
}
