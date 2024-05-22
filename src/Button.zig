const vaxis = @import("vaxis");

const Button = @This();

label: []const u8,
style: vaxis.Style = .{},

pub fn draw(self: Button, win: vaxis.Window) !void {
    win.fill(.{
        .char = .{
            .grapheme = " ",
            .width = 1,
        },
        .style = self.style,
    });
    const label_width = win.gwidth(self.label);
    const label_win = vaxis.widgets.alignment.center(win, label_width, 1);
    _ = try label_win.print(&.{.{ .text = self.label, .style = self.style }}, .{});
}

pub fn clicked(_: Button, win: vaxis.Window, mouse: ?vaxis.Mouse) bool {
    if (win.hasMouse(mouse)) |m| {
        return m.button == .left and m.type == .press;
    }
    return false;
}
