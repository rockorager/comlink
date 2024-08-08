const std = @import("std");
const vaxis = @import("vaxis");

const Scrollbar = @This();

/// character to use for the scrollbar
character: vaxis.Cell.Character = .{ .grapheme = "▐", .width = 1 },

/// style to draw the bar character with
style: vaxis.Style = .{},

/// The index of the bottom-most item, with 0 being "at the bottom"
bottom: usize = 0,

/// total items in the list
total: usize,

/// total items that fit within the view area
view_size: usize,

pub fn draw(self: Scrollbar, win: vaxis.Window) void {
    // don't draw when 0 items
    if (self.total < 1) return;

    // don't draw when all items can be shown
    if (self.view_size >= self.total) return;

    // (view_size / total) * window height = size of the scroll bar
    const bar_height = @max(std.math.divCeil(usize, self.view_size * win.height, self.total) catch unreachable, 1);

    // The row of the last cell of the bottom of the bar
    const bar_bottom = (win.height - 1) - (std.math.divCeil(usize, self.bottom * win.height, self.total) catch unreachable);

    var i: usize = 0;
    while (i <= bar_height) : (i += 1)
        win.writeCell(0, bar_bottom -| i, .{ .char = self.character, .style = self.style });
}
