const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const Scrollbar = @This();

/// character to use for the scrollbar
const character: vaxis.Cell.Character = .{ .grapheme = "▐", .width = 1 };
const empty: vaxis.Cell = .{ .char = character, .style = .{ .fg = .{ .index = 8 } } };

/// style to draw the bar character with
style: vaxis.Style = .{},

/// The index of the bottom-most item, with 0 being "at the bottom"
bottom: u16 = 0,

/// total items in the list
total: u16,

/// total items that fit within the view area
view_size: u16,

fn widget(self: *Scrollbar) vxfw.Widget {
    return .{
        .userdata = self,
        .drawFn = drawFn,
    };
}

fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *Scrollbar = @ptrCast(@alignCast(ptr));
    return self.draw(ctx);
}

pub fn draw(self: *Scrollbar, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const max = ctx.max.size();
    if (max.width == 0 or max.height == 0) {
        return .{
            .size = .{ .width = 0, .height = 0 },
            .widget = self.widget(),
            .buffer = &.{},
            .children = &.{},
        };
    }

    const surface = try vxfw.Surface.init(
        ctx.arena,
        self.widget(),
        .{ .width = 2, .height = max.height },
    );

    // don't draw when 0 items
    if (self.total < 1) return surface;

    // don't draw when all items can be shown
    if (self.view_size >= self.total) return surface;

    @memset(surface.buffer, empty);

    // (view_size / total) * window height = size of the scroll bar
    const bar_height = @max(std.math.divCeil(usize, self.view_size * max.height, self.total) catch unreachable, 1);

    // The row of the last cell of the bottom of the bar
    const bar_bottom = (max.height - 1) -| (std.math.divCeil(usize, self.bottom * max.height, self.total) catch unreachable);

    var i: usize = 0;
    while (i <= bar_height) : (i += 1)
        surface.writeCell(0, @intCast(bar_bottom -| i), .{ .char = character, .style = self.style });

    return surface;
}
