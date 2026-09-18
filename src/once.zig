const std = @import("std");

// std.once was deprecated (https://cookbook.ziglang.cc/07-04-run-once/) so we roll our own;
// and unlike the mutex-based std one this cant require an io cuz we have to once initialize an io
// in the ffi.
pub fn Once(comptime f: anytype) type {
    const Result = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

    return struct {
        const Self = @This();

        const State = enum(u8) {
            uninitialized,
            initializing,
            initialized,
        };

        state: std.atomic.Value(State) = .init(.uninitialized),
        result: Result = undefined,

        pub fn call(self: *Self) Result {
            if (self.state.load(.acquire) == .initialized) {
                return self.result;
            }

            if (self.state.cmpxchgStrong(
                .uninitialized,
                .initializing,
                .acq_rel,
                .acquire,
            ) == null) {
                self.result = f();

                self.state.store(.initialized, .release);

                return self.result;
            }

            while (self.state.load(.acquire) != .initialized) {
                std.atomic.spinLoopHint();
            }

            return self.result;
        }
    };
}

var test_call_count: usize = 0;

fn testOnceFn() usize {
    test_call_count += 1;

    return test_call_count;
}

var test_once: Once(testOnceFn) = .{};

test "once" {
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_once.call());
    try std.testing.expectEqual(@as(usize, 1), test_call_count);
}

// zlinter-disable no_global_vars
var concurrent_test_call_count: usize = 0;
var concurrent_test_once: Once(concurrentTestOnceFn) = .{};
// zlinter-enable no_global_vars

fn concurrentTestOnceFn() usize {
    return @atomicRmw(usize, &concurrent_test_call_count, .Add, 1, .acq_rel) + 1;
}

fn concurrentOnceWorker(
    once_ref: *Once(concurrentTestOnceFn),
    start: *std.atomic.Value(bool),
    out: *usize,
) void {
    while (!start.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    out.* = once_ref.call();
}

test "once concurrent callers execute initializer once" {
    concurrent_test_call_count = 0;
    concurrent_test_once = .{};

    var start = std.atomic.Value(bool).init(false);
    var results: [16]usize = undefined;
    var threads: [results.len]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        // if a later spawn fails, the already-created workers are still spinning on
        // `start`; release them and join before returning so we don't leak threads or
        // leave them reading invalid stack memory.
        start.store(true, .release);
        for (threads[0..spawned]) |thread| {
            thread.join();
        }
    }

    for (0..results.len) |idx| {
        threads[idx] = try std.Thread.spawn(
            .{},
            concurrentOnceWorker,
            .{
                &concurrent_test_once,
                &start,
                &results[idx],
            },
        );
        spawned += 1;
    }

    start.store(true, .release);

    for (threads) |thread| {
        thread.join();
    }

    for (results) |result| {
        try std.testing.expectEqual(@as(usize, 1), result);
    }

    try std.testing.expectEqual(@as(usize, 1), @atomicLoad(usize, &concurrent_test_call_count, .acquire));
}
