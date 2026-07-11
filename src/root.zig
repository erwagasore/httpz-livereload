//! Browser reload middleware for httpz.
//!
//! Injects a small script into HTML responses that opens an SSE connection
//! to the server. The connection is held open for the lifetime of the page.
//! A reload is triggered in three situations:
//!
//! - **Reconnection** — the SSE connection only drops when the server
//!   process dies. The browser reconnects, receives a new `init` event,
//!   and reloads.
//!
//! - **Explicit signal** — calling `reload()` pushes an SSE `reload`
//!   event to every connected browser (e.g. a separate static-file watcher
//!   reports that content changed).
//!
//! Rebuilding and restarting an application is deliberately outside this
//! middleware's scope. A development supervisor should own that process
//! lifecycle; browsers reload when their EventSource reconnects to the newly
//! started server.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.livereload);
const LiveReload = @This();

/// Process-neutral development supervision. This is separate from the httpz
/// middleware lifecycle and never runs from `init`, `execute`, or `deinit`.
pub const Supervisor = @import("supervisor.zig");

// ── Config ───────────────────────────────────────────────────────────────────

pub const Config = struct {
    /// SSE endpoint path.
    path: []const u8 = "/_livereload",

    /// Reconnection interval (milliseconds). Controls both the SSE
    /// `retry:` directive and the client-side reconnect delay. Lower
    /// values mean faster reload after a restart at the cost of a few
    /// extra TCP attempts while the server is down (negligible on
    /// localhost).
    retry_ms: u16 = 50,

    /// I/O implementation used for synchronization waits. Zig 0.16 applications should
    /// usually pass `init.io` from `main(init: std.process.Init)`.
    io: std.Io = std.Options.debug_io,
};

// ── State ────────────────────────────────────────────────────────────────────

// Immutable after init. All slices live on the server arena.
path: []const u8,
inject_snippet: []const u8,
sse_init_msg: []const u8,

// I/O implementation used by SSE synchronization waits.
io: std.Io,
stopping: std.atomic.Value(bool),

// Mutable shared state guarded by mu.
mu: std.Io.Mutex,
cond: std.Io.Condition,
generation: u64,
active_sse: u64,

// ── Init / deinit ────────────────────────────────────────────────────────────

pub fn init(config: Config, mc: httpz.MiddlewareConfig) !LiveReload {
    const arena = mc.arena;

    const path = try arena.dupe(u8, config.path);

    // Pre-format the injected script.
    //
    // On disconnect the EventSource error handler reconnects after
    // retry_ms. On reconnect the server sends a fresh "init" event;
    // if we already received one (ok==true), we know the server
    // restarted, so we reload the page.
    const inject_snippet = try std.fmt.allocPrint(arena,
        \\<script>(function(){{if(window.__lr)return;window.__lr=true;
        \\var ok=false,t,R={d};
        \\function c(){{var s=new EventSource("{s}");
        \\s.addEventListener("init",function(){{if(ok){{s.close();location.reload()}}ok=true}});
        \\s.addEventListener("reload",function(){{s.close();location.reload()}});
        \\s.addEventListener("error",function(){{s.close();clearTimeout(t);t=setTimeout(c,R)}})}}
        \\c()}})()</script>
    , .{ config.retry_ms, path });

    // Pre-format the SSE init message with the configured retry interval.
    const sse_init_msg = try std.fmt.allocPrint(
        arena,
        "retry:{d}\nevent:init\ndata:\n\n",
        .{config.retry_ms},
    );

    return .{
        .path = path,
        .inject_snippet = inject_snippet,
        .sse_init_msg = sse_init_msg,
        .io = config.io,
        .stopping = std.atomic.Value(bool).init(false),
        .mu = .init,
        .cond = .init,
        .generation = 0,
        .active_sse = 0,
    };
}

pub fn deinit(self: *LiveReload) void {
    self.stopping.store(true, .release);

    // Wake SSE writers parked on the condition variable and wait for them
    // to leave before httpz frees the middleware arena.
    self.mu.lockUncancelable(self.io);
    self.cond.broadcast(self.io);
    while (self.active_sse > 0) {
        self.cond.waitUncancelable(self.io, &self.mu);
    }
    self.mu.unlock(self.io);
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Signal all connected browsers to reload.
///
/// Use for cases that don't involve a server restart, e.g. a content
/// file changed on disk and the running server already serves the new
/// version.
pub fn reload(self: *LiveReload) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    self.generation +%= 1;
    self.cond.broadcast(self.io);
}

/// Extract the concrete `*LiveReload` from a type-erased `httpz.Middleware`
/// handle returned by `server.middleware()`.
///
/// ```zig
/// const mw = try server.middleware(LiveReload, .{});
/// const lr = LiveReload.from(mw);
/// lr.reload(); // manual trigger
/// ```
pub fn from(mw: anytype) *LiveReload {
    return @ptrCast(@alignCast(mw.ptr));
}

// ── Middleware execute ────────────────────────────────────────────────────────

// Takes *LiveReload (not *const) because Mutex.lock and atomic.cmpxchgStrong
// require mutable pointers in Zig. This is the standard pattern for middleware
// with interior-mutable state — httpz dispatches through *M which satisfies this.
pub fn execute(self: *LiveReload, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // SSE endpoint — respond and short-circuit.
    if (std.mem.eql(u8, req.url.path, self.path)) {
        return self.serveSSE(res);
    }

    // Normal path — run the handler chain, then inject if HTML.
    try executor.next();

    if (res.content_type == .HTML) {
        self.injectScript(res);
    }
}

// ── SSE ──────────────────────────────────────────────────────────────────────

const sse_reload = "event:reload\ndata:\n\n";

const SseContext = struct {
    lr: *LiveReload,
    io: std.Io,
};

fn serveSSE(self: *LiveReload, res: *httpz.Response) !void {
    // Reserve the writer before httpz spawns it. Without this handshake,
    // deinit could observe zero active writers and free the server arena while
    // the newly spawned thread was still waiting to run.
    try self.reserveSseWriter();
    errdefer self.releaseSseWriter();
    try res.startEventStream(SseContext{ .lr = self, .io = res.conn.io }, sseWriter);
}

fn reserveSseWriter(self: *LiveReload) error{Stopping}!void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    if (self.stopping.load(.acquire)) return error.Stopping;
    self.active_sse += 1;
}

fn releaseSseWriter(self: *LiveReload) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);

    self.active_sse -= 1;
    self.cond.broadcast(self.io);
}

/// Runs in an httpz-managed detached thread. `serveSSE` reserves this writer
/// before spawning it, so deinit cannot miss a thread that has not started yet.
fn sseWriter(ctx: SseContext, stream: std.Io.net.Stream) void {
    const self = ctx.lr;
    defer self.releaseSseWriter();

    if (self.stopping.load(.acquire)) return;

    var writer = stream.writer(ctx.io, &.{});
    const w = &writer.interface;

    w.writeAll(self.sse_init_msg) catch return;
    w.flush() catch return;

    // Park until a reload is signalled.
    {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        const gen = self.generation;
        while (self.generation == gen and !self.stopping.load(.acquire)) {
            self.cond.waitUncancelable(self.io, &self.mu);
        }
        if (self.stopping.load(.acquire)) return;
    }

    w.writeAll(sse_reload) catch return;
    w.flush() catch {};
}

// ── Script injection ─────────────────────────────────────────────────────────

fn injectScript(self: *const LiveReload, res: *httpz.Response) void {
    if (res.body.len > 0) {
        // Handler set body directly — allocate on the per-request arena.
        res.body = std.fmt.allocPrint(
            res.arena,
            "{s}{s}",
            .{ res.body, self.inject_snippet },
        ) catch |err| {
            log.warn("failed to inject livereload script: {}", .{err});
            return;
        };
    } else {
        // Handler used the writer API — append there.
        res.writer().writeAll(self.inject_snippet) catch |err| {
            log.warn("failed to inject livereload script: {}", .{err});
        };
    }
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
        .inject_snippet = "<script>lr()</script>",
        .sse_init_msg = "retry:50\nevent:init\ndata:\n\n",
        .io = std.Options.debug_io,
        .stopping = std.atomic.Value(bool).init(false),
        .mu = .init,
        .cond = .init,
        .generation = 0,
        .active_sse = 0,
    };
}

test "reload increments generation" {
    var lr = testInstance();
    try testing.expectEqual(@as(u64, 0), lr.generation);
    lr.reload();
    try testing.expectEqual(@as(u64, 1), lr.generation);
    lr.reload();
    try testing.expectEqual(@as(u64, 2), lr.generation);
}

test "SSE writer reservation participates in teardown before thread startup" {
    var lr = testInstance();

    try lr.reserveSseWriter();
    try testing.expectEqual(@as(u64, 1), lr.active_sse);

    lr.releaseSseWriter();
    try testing.expectEqual(@as(u64, 0), lr.active_sse);

    lr.stopping.store(true, .release);
    try testing.expectError(error.Stopping, lr.reserveSseWriter());
    try testing.expectEqual(@as(u64, 0), lr.active_sse);
}

test "init: copies configured path onto server arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var path_buf = [_]u8{ '/', '_', 'x' };
    const lr = try LiveReload.init(.{
        .path = path_buf[0..],
    }, .{
        .arena = arena.allocator(),
        .allocator = testing.allocator,
    });

    path_buf[2] = 'y';
    try testing.expectEqualStrings("/_x", lr.path);
}

test "injectScript: appends to body" {
    var lr = testInstance();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.res.content_type = .HTML;
    ht.res.body = "<html></html>";

    lr.injectScript(ht.res);

    try testing.expectEqualStrings("<html></html><script>lr()</script>", ht.res.body);
}

test "injectScript: appends to writer when body is empty" {
    var lr = testInstance();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();

    ht.res.content_type = .HTML;
    try ht.res.writer().writeAll("<html></html>");

    lr.injectScript(ht.res);

    const buffered = ht.res.writer().buffered();
    try testing.expectEqualStrings("<html></html><script>lr()</script>", buffered);
}

test "execute: non-HTML responses pass through" {
    var lr = testInstance();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");

    ht.res.content_type = .JSON;
    ht.res.body = "{\"ok\":true}";

    var exec = NoopExecutor{};
    try lr.execute(ht.req, ht.res, &exec);

    try testing.expect(exec.called);
    try testing.expectEqualStrings("{\"ok\":true}", ht.res.body);
}

test "execute: HTML responses get script injected" {
    var lr = testInstance();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");

    ht.res.content_type = .HTML;
    ht.res.body = "<h1>hi</h1>";

    var exec = NoopExecutor{};
    try lr.execute(ht.req, ht.res, &exec);

    try testing.expect(exec.called);
    try testing.expectEqualStrings("<h1>hi</h1><script>lr()</script>", ht.res.body);
}
