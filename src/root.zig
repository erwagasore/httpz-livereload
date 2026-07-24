//! Browser reload middleware for httpz.
//!
//! HTML responses receive a small polling client. The client compares the
//! server's current version with the version embedded in the page and reloads
//! when they differ. A new process starts with a random version; `reload()`
//! increments it for in-process changes such as updated static files.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.livereload);
const LiveReload = @This();

/// Development process supervision. This is separate from the middleware
/// lifecycle and delegates source watching and rebuilding to `zig build
/// --watch install`.
pub const Supervisor = @import("supervisor.zig");

pub const Config = struct {
    /// Browser polling endpoint.
    path: []const u8 = "/_livereload",

    /// Delay between browser version checks.
    poll_interval_ms: u16 = 500,

    /// Used once during initialization to generate the process version.
    io: std.Io = std.Options.debug_io,
};

// Immutable after initialization. The path is owned by the server arena.
path: []const u8,
poll_interval_ms: u16,

// A random initial value distinguishes server processes. In-process content
// changes increment the same value.
version: std.atomic.Value(u64),

pub fn init(config: Config, mc: httpz.MiddlewareConfig) !LiveReload {
    if (config.poll_interval_ms == 0) return error.InvalidPollInterval;

    var initial_version: u64 = undefined;
    config.io.random(std.mem.asBytes(&initial_version));

    return .{
        .path = try mc.arena.dupe(u8, config.path),
        .poll_interval_ms = config.poll_interval_ms,
        .version = .init(initial_version),
    };
}

/// Signal browsers to reload after an in-process content change.
pub fn reload(self: *LiveReload) void {
    _ = self.version.fetchAdd(1, .monotonic);
}

/// Adapter for watcher APIs that accept `(?*anyopaque) void` callbacks.
pub fn reloadCallback(context: ?*anyopaque) void {
    const self: *LiveReload = @ptrCast(@alignCast(context.?));
    self.reload();
}

/// Extract the concrete middleware from the handle returned by
/// `server.middleware()`.
pub fn from(middleware: anytype) *LiveReload {
    return @ptrCast(@alignCast(middleware.ptr));
}

pub fn execute(self: *LiveReload, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    if (std.mem.eql(u8, req.url.path, self.path)) {
        return self.serveVersion(res);
    }

    try executor.next();

    // Streaming and disowned responses have already touched the wire.
    if (res.written or res.chunked) return;
    if (!isHtml(res)) return;
    if (headerValue(res, "content-encoding") != null) return;

    self.injectScript(res);
}

fn serveVersion(self: *const LiveReload, res: *httpz.Response) !void {
    res.content_type = .TEXT;
    res.header("Cache-Control", "no-store");
    res.body = try std.fmt.allocPrint(
        res.arena,
        "{x}",
        .{self.version.load(.monotonic)},
    );
}

const script_format =
    \\<script>(function(){{if(window.__lr)return;window.__lr=true;
    \\var v="{x}",u="{s}",d={d};
    \\async function p(){{try{{var r=await fetch(u,{{cache:"no-store"}});
    \\if(r.ok&&(await r.text())!==v){{location.reload();return}}}}catch(_){{}}
    \\setTimeout(p,d)}}p()}})()</script>
;

fn injectScript(self: *const LiveReload, res: *httpz.Response) void {
    const args = .{ self.version.load(.monotonic), self.path, self.poll_interval_ms };
    const script_len = std.fmt.count(script_format, args);
    const writer = res.writer();

    // This mirrors httpz.Response.write(): writer output wins when non-empty.
    // Append directly instead of duplicating the potentially large buffered
    // body. Reserving first prevents a partial script on allocation failure.
    if (writer.buffered().len > 0) {
        writer.ensureUnusedCapacity(script_len) catch |err| {
            log.warn("failed to reserve livereload script space: {}", .{err});
            return;
        };
        writer.print(script_format, args) catch |err| {
            log.warn("failed to inject livereload script: {}", .{err});
        };
        return;
    }

    const output_len = std.math.add(usize, res.body.len, script_len) catch {
        log.warn("HTML response is too large for livereload injection", .{});
        return;
    };
    const output = res.arena.alloc(u8, output_len) catch |err| {
        log.warn("failed to inject livereload script: {}", .{err});
        return;
    };
    @memcpy(output[0..res.body.len], res.body);
    _ = std.fmt.bufPrint(output[res.body.len..], script_format, args) catch unreachable;
    res.body = output;
}

fn isHtml(res: *const httpz.Response) bool {
    if (res.content_type) |content_type| return content_type == .HTML;
    const value = headerValue(res, "content-type") orelse return false;
    return std.ascii.startsWithIgnoreCase(value, "text/html");
}

fn headerValue(res: *const httpz.Response, name: []const u8) ?[]const u8 {
    var iterator = res.headers.iterator();
    while (iterator.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, name)) return header.value;
    }
    return null;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

const NoopExecutor = struct {
    called: bool = false,

    pub fn next(self: *NoopExecutor) !void {
        self.called = true;
    }
};

fn testInstance() LiveReload {
    return .{
        .path = "/_livereload",
        .poll_interval_ms = 500,
        .version = .init(42),
    };
}

fn effectiveBody(res: *httpz.Response) []const u8 {
    const buffered = res.writer().buffered();
    return if (buffered.len > 0) buffered else res.body;
}

test "reload increments version" {
    var live_reload = testInstance();
    try testing.expectEqual(@as(u64, 42), live_reload.version.load(.monotonic));
    live_reload.reload();
    try testing.expectEqual(@as(u64, 43), live_reload.version.load(.monotonic));
}

test "reloadCallback increments version" {
    var live_reload = testInstance();
    reloadCallback(&live_reload);
    try testing.expectEqual(@as(u64, 43), live_reload.version.load(.monotonic));
}

test "init rejects a zero polling interval" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.InvalidPollInterval, LiveReload.init(.{
        .poll_interval_ms = 0,
    }, .{
        .arena = arena.allocator(),
        .allocator = testing.allocator,
    }));
}

test "init copies configured path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var path = [_]u8{ '/', '_', 'x' };
    const live_reload = try LiveReload.init(.{ .path = path[0..] }, .{
        .arena = arena.allocator(),
        .allocator = testing.allocator,
    });

    path[2] = 'y';
    try testing.expectEqualStrings("/_x", live_reload.path);
}

test "version endpoint returns current no-store version" {
    var live_reload = testInstance();
    var http_test = httpz.testing.init(.{});
    defer http_test.deinit();
    http_test.url("/_livereload");

    var executor = NoopExecutor{};
    try live_reload.execute(http_test.req, http_test.res, &executor);

    try testing.expect(!executor.called);
    try testing.expectEqual(httpz.ContentType.TEXT, http_test.res.content_type.?);
    try testing.expectEqualStrings("2a", http_test.res.body);
    try testing.expectEqualStrings("no-store", headerValue(http_test.res, "cache-control").?);
}

test "HTML body receives polling script" {
    var live_reload = testInstance();
    var http_test = httpz.testing.init(.{});
    defer http_test.deinit();
    http_test.url("/");
    http_test.res.content_type = .HTML;
    http_test.res.body = "<h1>hello</h1>";

    var executor = NoopExecutor{};
    try live_reload.execute(http_test.req, http_test.res, &executor);

    try testing.expect(executor.called);
    try testing.expect(std.mem.startsWith(u8, http_test.res.body, "<h1>hello</h1><script>"));
    try testing.expect(std.mem.indexOf(u8, http_test.res.body, "var v=\"2a\"") != null);
}

test "writer buffer takes precedence and receives injection in place" {
    var live_reload = testInstance();
    var http_test = httpz.testing.init(.{});
    defer http_test.deinit();
    http_test.url("/");
    http_test.res.content_type = .HTML;
    http_test.res.body = "ignored";
    try http_test.res.writer().writeAll("<p>writer</p>");

    var executor = NoopExecutor{};
    try live_reload.execute(http_test.req, http_test.res, &executor);

    try testing.expectEqualStrings("ignored", http_test.res.body);
    try testing.expect(std.mem.startsWith(
        u8,
        http_test.res.writer().buffered(),
        "<p>writer</p><script>",
    ));
}

test "manual HTML content type is recognized case-insensitively" {
    var live_reload = testInstance();
    var http_test = httpz.testing.init(.{});
    defer http_test.deinit();
    http_test.url("/");
    http_test.res.header("Content-Type", "Text/HTML; charset=utf-8");
    http_test.res.body = "<p>hello</p>";

    var executor = NoopExecutor{};
    try live_reload.execute(http_test.req, http_test.res, &executor);

    try testing.expect(std.mem.indexOf(u8, http_test.res.body, "<script>") != null);
}

test "non-HTML responses pass through" {
    var live_reload = testInstance();
    var http_test = httpz.testing.init(.{});
    defer http_test.deinit();
    http_test.url("/");
    http_test.res.content_type = .JSON;
    http_test.res.body = "{\"ok\":true}";

    var executor = NoopExecutor{};
    try live_reload.execute(http_test.req, http_test.res, &executor);

    try testing.expectEqualStrings("{\"ok\":true}", effectiveBody(http_test.res));
}

test "written chunked and encoded HTML responses pass through" {
    const Case = enum { written, chunked, encoded };
    inline for ([_]Case{ .written, .chunked, .encoded }) |case| {
        var live_reload = testInstance();
        var http_test = httpz.testing.init(.{});
        defer http_test.deinit();
        http_test.url("/");
        http_test.res.content_type = .HTML;
        http_test.res.body = "<p>hello</p>";

        switch (case) {
            .written => http_test.res.written = true,
            .chunked => http_test.res.chunked = true,
            .encoded => http_test.res.header("Content-Encoding", "gzip"),
        }

        var executor = NoopExecutor{};
        try live_reload.execute(http_test.req, http_test.res, &executor);

        try testing.expectEqualStrings("<p>hello</p>", effectiveBody(http_test.res));
    }
}
