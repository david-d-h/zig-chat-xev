const std = @import("std");
const c_allocator = std.heap.c_allocator;

inline fn malloc(nbytes: usize) []u8 {
    return c_allocator.alloc(u8, nbytes) catch @panic("OOM");
}

inline fn mcreate(comptime T: type) !*T {
    return c_allocator.create(T);
}

inline fn mcreateOrPanic(comptime T: type) *T {
    return mcreate(T) catch @panic("OOM");
}

inline fn free(mem: anytype) void {
    c_allocator.destroy(mem);
}

inline fn freeM(mem: anytype) void {
    c_allocator.free(mem);
}

const xev = @import("xev");

const address: std.net.Address = .initIp4([4]u8{ 127, 0, 0, 1 }, 8080);

const default_backlog: u31 = 128;

const _ = xev.available() or @compileError("can't run this application on the current platform");

pub fn main() !void {
    _ = xev.available() or @panic("can't run this application on the current platform");

    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    const server = try xev.TCP.init(address);
    try server.bind(address);
    try server.listen(default_backlog);

    var c_accept: xev.Completion = undefined;
    server.accept(&loop, &c_accept, void, null, (struct {
        fn callback(
            _: ?*void,
            l: *xev.Loop,
            _: *xev.Completion,
            r: xev.AcceptError!xev.TCP,
        ) xev.CallbackAction {
            const client: xev.TCP = r catch unreachable;
            handleClient(l, client);
            return .rearm;
        }
    }).callback);

    // The accept callback perpetually rearms itself.
    // The loop will never be done, and thus this function never exits.
    try loop.run(.until_done);
}

fn closeCallback(
    _: ?*void,
    _: *xev.Loop,
    completion: *xev.Completion,
    _: xev.TCP,
    _: xev.CloseError!void,
) xev.CallbackAction {
    free(completion);
    return .disarm;
}

const Ctx = struct { r_buffer: [1024]u8 = .{0} ** 1024 };

fn handleClient(loop: *xev.Loop, client: xev.TCP) void {
    const context = mcreateOrPanic(Ctx);
    context.r_buffer = .{0} ** 1024;

    const c_read = mcreateOrPanic(xev.Completion);
    client.read(loop, c_read, .{ .slice = &context.r_buffer }, Ctx, context, readLoopCallback);
}

fn readLoopCallback(
    ctx: ?*Ctx,
    loop: *xev.Loop,
    completion: *xev.Completion,
    client: xev.TCP,
    buffer: xev.ReadBuffer,
    result: xev.ReadError!usize,
) xev.CallbackAction {
    const context = ctx.?;

    const n_read: usize = result catch {
        const c_close = mcreateOrPanic(xev.Completion);
        client.close(loop, c_close, void, null, closeCallback);
        free(completion);
        free(context);
        return .disarm;
    };

    const content = rBufferAsSlice(&buffer, n_read);
    justWrite(content, loop, client);

    return .rearm;
}

fn justWrite(
    content: []const u8,
    loop: *xev.Loop,
    client: xev.TCP,
) void {
    const length_ptr = mcreateOrPanic(usize);
    length_ptr.* = content.len;

    const c_write = mcreateOrPanic(xev.Completion);
    client.write(loop, c_write, .{ .slice = content }, usize, length_ptr, (struct {
        fn callback(
            l: ?*usize,
            innerLoop: *xev.Loop,
            completion: *xev.Completion,
            innerClient: xev.TCP,
            buffer: xev.WriteBuffer,
            result: xev.WriteError!usize,
        ) xev.CallbackAction {
            defer free(l.?);
            defer free(completion);

            const length: usize = l.?.*;

            const n_written: usize = result catch {
                const c_close = mcreateOrPanic(xev.Completion);
                innerClient.close(innerLoop, c_close, void, null, closeCallback);
                return .disarm;
            };

            const data = wBufferAsSlice(&buffer, length);

            // SAFETY: the buffer is guaranteed to be the user provided content,
            //         so we can ignore the lifetime of &buffer since we are now
            //         dealing with user provided data.
            if (length > n_written) {
                justWrite(data[n_written..length], innerLoop, innerClient);
                return .disarm;
            }

            return .disarm;
        }
    }).callback);
}

inline fn rBufferAsSlice(buffer: *const xev.ReadBuffer, len: usize) []const u8 {
    return switch (buffer.*) {
        inline .array, .slice => |data| data[0..len],
    };
}

/// Turn the given WriteBuffer into a slice of constant bytes.
///
/// NOTE: beware! The returned slice may have the same lifetime as the
///       provided buffer, as the writer (union) may be an owned array.
inline fn wBufferAsSlice(buffer: *const xev.WriteBuffer, len: usize) []const u8 {
    return switch (buffer.*) {
        .slice => |data| data[0..len],
        .array => |data| data.array[0..len],
    };
}

const testing = std.testing;

test rBufferAsSlice {
    var bytes = [5]u8{ 1, 2, 3, 0, 0 };

    const bslice: xev.ReadBuffer = .{ .slice = &bytes };
    const bslice_as_slice = rBufferAsSlice(&bslice, 3);
    try testing.expectEqualSlices(u8, &[3]u8{ 1, 2, 3 }, bslice_as_slice);

    const barray: xev.ReadBuffer = .{ .array = bytes ++ (.{0} ** 27) };
    const barray_as_slice = rBufferAsSlice(&barray, 3);
    try testing.expectEqualSlices(u8, &[3]u8{ 1, 2, 3 }, barray_as_slice);
}
