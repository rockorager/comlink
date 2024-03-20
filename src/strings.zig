const std = @import("std");
const assert = std.debug.assert;
const vaxis = @import("vaxis");
const ziglyph = vaxis.ziglyph;

/// calculates the number of lines needed to display a message
pub fn lineCountForWindow(win: vaxis.Window, message: []const u8) usize {
    if (win.width == 0) return 0;
    var row: usize = 0;
    var col: usize = 0;
    var wrapped: bool = false;
    var word_iter = ziglyph.WordIterator.init(message) catch {
        // if it's not valid unicode, we'll just divide by length and maybe
        // we'll be wrong...oh well
        return std.math.divFloor(usize, message.len, win.width) catch unreachable;
    };
    while (word_iter.next()) |word| {
        // break lines when we need
        if (word.bytes[0] == '\r' or word.bytes[0] == '\n') {
            row += 1;
            col = 0;
            wrapped = false;
            continue;
        }
        // break lines when we can't fit this word, and the word isn't longer
        // than our width
        const word_width = win.gwidth(word.bytes);
        if (word_width + col > win.width and word_width < win.width) {
            row += 1;
            col = 0;
            wrapped = true;
        }
        if (row >= win.height) return row;
        // don't print whitespace in the first column, unless we had a hard
        // break
        if (col == 0 and std.mem.eql(u8, word.bytes, " ") and wrapped) continue;
        var iter = ziglyph.GraphemeIterator.init(word.bytes);
        while (iter.next()) |grapheme| {
            if (col >= win.width) {
                row += 1;
                col = 0;
                wrapped = true;
            }
            const s = grapheme.slice(word.bytes);
            const w = win.gwidth(s);
            col += w;
        }
    }
    return row + 1;
}
