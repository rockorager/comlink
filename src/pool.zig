const std = @import("std");

const Condition = std.Thread.Condition;
const Mutex = std.Thread.Mutex;

/// BytePool is a thread safe buffer. Use it by Allocating a given number of bytes, which will block
/// until one is available. The returned Slice structure contains a reference to a slice within the
/// pool. This slice will always belong to the Slice until deinit is called.
///
/// This data structure is useful for receiving messages over-the-wire and sending to another thread
/// for processing, while providing some level of backpressure on the read side. For example, we
/// could be reading messages from the wire and sending into a queue for processing. We could read
/// 10 messages off the connection, but the queue is blocked doing an expensive operation. We are
/// still able to read until our BytePool is out of capacity.
///
/// For IRC, we use this because messages over the wire *could* be up to 4192 bytes, but commonly
/// are less than 100. Instead of a pool of buffers each 4192, we write messages of exact length
/// into this pool to more efficiently pack the memory
pub fn BytePool(comptime size: usize) type {
    return struct {
        const Self = @This();

        pub const Slice = struct {
            idx: usize,
            len: usize,
            pool: *Self,

            /// Frees resources associated with Buffer
            pub fn deinit(self: Slice) void {
                self.pool.mutex.lock();
                defer self.pool.mutex.unlock();
                @memset(self.pool.free_list[self.idx .. self.idx + self.len], true);
                // Signal that we may have capacity now
                self.pool.buffer_deinited.signal();
            }

            /// Returns the actual slice of this buffer
            pub fn slice(self: Slice) []u8 {
                return self.pool.buffer[self.idx .. self.idx + self.len];
            }
        };

        buffer: [size]u8 = undefined,
        free_list: [size]bool = undefined,
        mutex: Mutex = .{},
        /// The index of the next potentially available byte
        next_idx: usize = 0,

        buffer_deinited: Condition = .{},

        pub fn init(self: *Self) void {
            @memset(&self.free_list, true);
        }

        /// Get a buffer of size n. Blocks until one is available
        pub fn alloc(self: *Self, n: usize) Slice {
            std.debug.assert(n < size);
            self.mutex.lock();
            defer self.mutex.unlock();
            while (true) {
                if (self.getBuffer(n)) |buf| return buf;
                self.buffer_deinited.wait(&self.mutex);
            }
        }

        fn getBuffer(self: *Self, n: usize) ?Slice {
            var start: usize = self.next_idx;
            var did_wrap: bool = false;
            while (true) {
                if (start + n >= self.buffer.len) {
                    if (did_wrap) return null;
                    did_wrap = true;
                    start = 0;
                }

                const next_true = std.mem.indexOfScalarPos(bool, &self.free_list, start, true) orelse {
                    if (did_wrap) return null;
                    did_wrap = true;
                    start = 0;
                    continue;
                };

                if (next_true + n >= self.buffer.len) {
                    if (did_wrap) return null;
                    did_wrap = true;
                    start = 0;
                    continue;
                }

                // Get our potential slice
                const maybe_slice = self.free_list[next_true .. next_true + n];
                // Check that the entire thing is true
                if (std.mem.indexOfScalar(bool, maybe_slice, false)) |idx| {
                    // We have a false, increment and look again
                    start = next_true + idx + 1;
                    continue;
                }
                // Set this slice in the free_list as not free
                @memset(maybe_slice, false);
                // Update next_idx
                self.next_idx = next_true + n;
                return .{
                    .idx = next_true,
                    .len = n,
                    .pool = self,
                };
            }
        }
    };
}
