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
//!   event to every connected browser (e.g. a content file changed on
//!   disk and the running server already serves the new version).
//!
//! - **Directory watch** — calling `watchDir()` starts a background
//!   thread that polls a directory tree for file changes. On change,
//!   an optional callback is invoked (e.g. to re-parse content), then
//!   all connected browsers are signalled to reload.
//!
//! A background thread can optionally watch the server binary on disk.
//! When its mtime changes (e.g. `zig build --watch` rebuilt it), the
//! middleware exits the process so a wrapper can restart it with new code.
//! Browsers reload after their EventSource reconnects to the new server.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.livereload);
const LiveReload = @This();

// ── Config ───────────────────────────────────────────────────────────────────

pub const Config = struct {
    /// SSE endpoint path.
    path: []const u8 = "/_livereload",

    /// Watch the server binary for changes. On change, exit(0) so a
    /// restart wrapper can relaunch with new code.
    watch: bool = true,

    /// Binary polling interval (nanoseconds).
    watch_interval_ns: u64 = 50 * std.time.ns_per_ms,

    /// Reconnection interval (milliseconds). Controls both the SSE
    /// `retry:` directive and the client-side reconnect delay. Lower
    /// values mean faster reload after a restart at the cost of a few
    /// extra TCP attempts while the server is down (negligible on
    /// localhost).
    retry_ms: u16 = 50,

    /// I/O implementation used for blocking filesystem operations,
    /// sleeps, and synchronization waits. Zig 0.16 applications should
    /// usually pass `init.io` from `main(init: std.process.Init)`.
    io: std.Io = std.Options.debug_io,
};

// ── State ────────────────────────────────────────────────────────────────────

// Immutable after init. All slices live on the server arena.
path: []const u8,
inject_snippet: []const u8,
sse_init_msg: []const u8,

// Binary watcher — immutable after init. Safe to read from the watcher
// thread because Thread.spawn provides a happens-before guarantee.
exe_path: ?[:0]const u8,
exe_mtime: i128,
watch_interval_ns: u64,

// Lazy-spawn flag. The watcher can't be started in init() because httpz's
// middleware() copies the returned value into the arena — `self` isn't a
// stable pointer until execute() is called on the arena-allocated copy.
watcher_spawned: std.atomic.Value(bool),

// Long-lived allocations owned by httpz's server arena. httpz calls
// deinit() before freeing this arena, so watcher threads must be joined
// before deinit() returns.
arena: std.mem.Allocator,

// General allocator used for middleware-owned bookkeeping that deinit()
// explicitly frees.
allocator: std.mem.Allocator,

// I/O implementation used by watcher threads and synchronization waits.
io: std.Io,

// Background watcher threads owned by this middleware.
threads_mu: std.Io.Mutex,
threads: std.ArrayList(std.Thread),
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

    // Resolve executable path and initial mtime.
    var exe_path: ?[:0]const u8 = null;
    var exe_mtime: i128 = 0;
    if (config.watch) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.process.executablePath(config.io, &buf)) |n| {
            exe_path = try arena.dupeZ(u8, buf[0..n]);
            exe_mtime = fileMtime(config.io, exe_path.?);
        } else |_| {}
    }

    return .{
        .path = path,
        .inject_snippet = inject_snippet,
        .sse_init_msg = sse_init_msg,
        .exe_path = exe_path,
        .exe_mtime = exe_mtime,
        .watch_interval_ns = config.watch_interval_ns,
        .watcher_spawned = std.atomic.Value(bool).init(false),
        .arena = arena,
        .allocator = mc.allocator,
        .io = config.io,
        .threads_mu = .init,
        .threads = .empty,
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

    self.threads_mu.lockUncancelable(self.io);
    defer self.threads_mu.unlock(self.io);
    for (self.threads.items) |thread| {
        thread.join();
    }
    self.threads.deinit(self.allocator);
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

// ── Directory watching ───────────────────────────────────────────────────────

pub const OnChangeFn = struct {
    cb: *const fn (*anyopaque) anyerror!void,
    ctx: *anyopaque,
};

pub const WatchDirOpts = struct {
    /// Poll interval in nanoseconds. Default 50ms.
    poll_ns: u64 = 50 * std.time.ns_per_ms,

    /// Optional callback invoked when a change is detected, *before*
    /// signalling browsers to reload. Return an error to skip the
    /// reload for this change (e.g. if re-parsing content failed).
    on_change: ?OnChangeFn = null,
};

/// Watch a directory tree for file changes. When a modification is
/// detected, the optional `on_change` callback is invoked first, then
/// all connected browsers are signalled to reload.
///
/// The `dir` path is duped onto the server arena so callers may pass
/// transient slices safely.
///
/// Can be called multiple times for different directories. Each call
/// spawns a lightweight background thread.
///
/// ```zig
/// const lr = LiveReload.from(mw);
/// lr.watchDir("content", .{
///     .poll_ns = 50 * std.time.ns_per_ms,
///     .on_change = .{ .cb = &MyApp.reloadContent, .ctx = @ptrCast(app) },
/// });
/// lr.watchDir("static", .{});
/// ```
pub fn watchDir(self: *LiveReload, dir: []const u8, opts: WatchDirOpts) void {
    if (self.stopping.load(.acquire)) return;

    const owned = self.arena.dupe(u8, dir) catch |err| {
        log.warn("could not allocate watch path for '{s}': {}", .{ dir, err });
        return;
    };
    self.spawnBackground(watchDirLoop, .{ self, owned, opts }) catch |err| {
        if (err != error.Stopping) {
            log.warn("could not start directory watcher for '{s}': {}", .{ dir, err });
        }
    };
}

fn watchDirLoop(self: *LiveReload, dir: []const u8, opts: WatchDirOpts) void {
    var prev = dirMtime(self.io, dir);
    while (!self.stopping.load(.acquire)) {
        sleepNs(self, opts.poll_ns);
        if (self.stopping.load(.acquire)) break;
        const curr = dirMtime(self.io, dir);
        if (curr != prev) {
            prev = curr;
            if (opts.on_change) |handler| {
                handler.cb(handler.ctx) catch |err| {
                    log.warn("watch callback error for '{s}': {}", .{ dir, err });
                    continue;
                };
            }
            log.info("change detected in '{s}' — reloading browsers", .{dir});
            self.reload();
        }
    }
}

/// Return the maximum mtime across all files in a directory tree.
/// Uses allocation-free manual recursion so it's safe to call from
/// any thread without a shared allocator.
fn dirMtime(io: std.Io, path: []const u8) i128 {
    var best: i128 = 0;
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    walkDirMtime(io, dir, &best);
    return best;
}

fn walkDirMtime(io: std.Io, dir: std.Io.Dir, best: *i128) void {
    const dir_stat = dir.stat(io) catch null;
    if (dir_stat) |stat| {
        if (stat.mtime.nanoseconds > best.*) best.* = stat.mtime.nanoseconds;
    }

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                if (stat.mtime.nanoseconds > best.*) best.* = stat.mtime.nanoseconds;
            },
            .directory => {
                var sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                walkDirMtime(io, sub, best);
            },
            else => {},
        }
    }
}

// ── Middleware execute ────────────────────────────────────────────────────────

// Takes *LiveReload (not *const) because Mutex.lock and atomic.cmpxchgStrong
// require mutable pointers in Zig. This is the standard pattern for middleware
// with interior-mutable state — httpz dispatches through *M which satisfies this.
pub fn execute(self: *LiveReload, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // Lazily spawn the binary watcher on first request. At this point
    // `self` is the stable, arena-allocated pointer.
    if (self.exe_path != null and
        self.watcher_spawned.cmpxchgStrong(false, true, .release, .monotonic) == null)
    {
        self.spawnBackground(watchBinaryLoop, .{self}) catch |err| {
            self.watcher_spawned.store(false, .release);
            if (err != error.Stopping) {
                log.warn("could not start binary watcher: {}", .{err});
            }
        };
    }

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
    try res.startEventStream(SseContext{ .lr = self, .io = res.conn.io }, sseWriter);
}

/// Runs in an httpz-managed detached thread.
fn sseWriter(ctx: SseContext, stream: std.Io.net.Stream) void {
    const self = ctx.lr;

    self.mu.lockUncancelable(self.io);
    if (self.stopping.load(.acquire)) {
        self.mu.unlock(self.io);
        return;
    }
    self.active_sse += 1;
    self.mu.unlock(self.io);
    defer {
        self.mu.lockUncancelable(self.io);
        self.active_sse -= 1;
        self.cond.broadcast(self.io);
        self.mu.unlock(self.io);
    }

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

// ── Binary watcher ───────────────────────────────────────────────────────────

fn watchBinaryLoop(self: *LiveReload) void {
    const path = self.exe_path orelse return;
    while (!self.stopping.load(.acquire)) {
        sleepNs(self, self.watch_interval_ns);
        if (self.stopping.load(.acquire)) break;
        const mtime = fileMtime(self.io, path);
        if (mtime != self.exe_mtime) {
            // Don't send reload — just exit. The browser's EventSource
            // will error, then reconnect once the restart loop brings
            // the new binary up. On reconnect it receives "init" with
            // ok=true → location.reload(). This guarantees the reload
            // only fires when the NEW server is ready to serve CSS/fonts.
            std.process.exit(0);
        }
    }
}

fn spawnBackground(self: *LiveReload, comptime func: anytype, args: anytype) !void {
    self.threads_mu.lockUncancelable(self.io);
    defer self.threads_mu.unlock(self.io);

    if (self.stopping.load(.acquire)) return error.Stopping;
    try self.threads.ensureUnusedCapacity(self.allocator, 1);

    const thread = try std.Thread.spawn(.{}, func, args);
    self.threads.appendAssumeCapacity(thread);
}

fn fileMtime(io: std.Io, path: [:0]const u8) i128 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return 0;
    return stat.mtime.nanoseconds;
}

fn sleepNs(self: *LiveReload, ns: u64) void {
    var remaining = ns;
    while (remaining > 0 and !self.stopping.load(.acquire)) {
        const chunk = @min(remaining, 50 * std.time.ns_per_ms);
        std.Io.sleep(self.io, .fromNanoseconds(@intCast(chunk)), .awake) catch {};
        remaining -= chunk;
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
        .exe_path = null,
        .exe_mtime = 0,
        .watch_interval_ns = 0,
        .watcher_spawned = std.atomic.Value(bool).init(false),
        .arena = testing.allocator,
        .allocator = testing.allocator,
        .io = std.Options.debug_io,
        .threads_mu = .init,
        .threads = .empty,
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

test "init: copies configured path onto server arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var path_buf = [_]u8{ '/', '_', 'x' };
    const lr = try LiveReload.init(.{
        .path = path_buf[0..],
        .watch = false,
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

test "dirMtime: returns 0 for non-existent path" {
    try testing.expectEqual(@as(i128, 0), dirMtime(std.Options.debug_io, "__nonexistent_dir__"));
}

test "dirMtime: returns non-zero for existing directory with files" {
    // Use src/ which always has root.zig
    const mtime = dirMtime(std.Options.debug_io, "src");
    try testing.expect(mtime > 0);
}

test "WatchDirOpts: defaults" {
    const opts = WatchDirOpts{};
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), opts.poll_ns);
    try testing.expect(opts.on_change == null);
}
