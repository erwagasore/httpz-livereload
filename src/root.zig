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
//! middleware signals browsers and exits the process so a wrapper can
//! restart it with new code.

const std = @import("std");
const httpz = @import("httpz");

const log = std.log.scoped(.livereload);
const LiveReload = @This();

// ── Config ───────────────────────────────────────────────────────────────────

pub const Config = struct {
    /// SSE endpoint path.
    path: []const u8 = "/_livereload",

    /// Watch the server binary for changes. On change, signal browsers
    /// and exit(0) so a restart wrapper can relaunch with new code.
    watch: bool = true,

    /// Binary polling interval (nanoseconds).
    watch_interval_ns: u64 = 50 * std.time.ns_per_ms,

    /// Reconnection interval (milliseconds). Controls both the SSE
    /// `retry:` directive and the client-side reconnect delay. Lower
    /// values mean faster reload after a restart at the cost of a few
    /// extra TCP attempts while the server is down (negligible on
    /// localhost).
    retry_ms: u16 = 50,
};

// ── State ────────────────────────────────────────────────────────────────────

// Immutable after init. All slices live on the server arena;
// path points into the Config literal or the server arena.
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

// Server arena — never freed, lives as long as the process. Used to
// allocate paths passed to detached watcher threads so their memory
// is guaranteed to outlive the thread.
arena: std.mem.Allocator,

// Mutable shared state guarded by mu.
mu: std.Thread.Mutex,
cond: std.Thread.Condition,
generation: u64,

// ── Init / deinit ────────────────────────────────────────────────────────────

pub fn init(config: Config, mc: httpz.MiddlewareConfig) !LiveReload {
    const arena = mc.arena;

    // Pre-format the injected script.
    //
    // On disconnect the EventSource error handler reconnects after
    // retry_ms. On reconnect the server sends a fresh "init" event;
    // if we already received one (ok==true), we know the server
    // restarted, so we reload the page.
    const inject_snippet = try std.fmt.allocPrint(arena,
        \\<script>(function(){{var ok=false,t,R={d};
        \\function c(){{var s=new EventSource("{s}");
        \\s.addEventListener("init",function(){{if(ok){{s.close();location.reload()}}ok=true}});
        \\s.addEventListener("reload",function(){{s.close();location.reload()}});
        \\s.addEventListener("error",function(){{s.close();clearTimeout(t);t=setTimeout(c,R)}})}}
        \\c()}})()</script>
    , .{ config.retry_ms, config.path });

    // Pre-format the SSE init message with the configured retry interval.
    const sse_init_msg = try std.fmt.allocPrint(arena,
        "retry:{d}\nevent:init\ndata:\n\n",
        .{config.retry_ms},
    );

    // Resolve executable path and initial mtime.
    var exe_path: ?[:0]const u8 = null;
    var exe_mtime: i128 = 0;
    if (config.watch) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExePath(&buf)) |p| {
            exe_path = try arena.dupeZ(u8, p);
            exe_mtime = fileMtime(exe_path.?);
        } else |_| {}
    }

    return .{
        .path = config.path,
        .inject_snippet = inject_snippet,
        .sse_init_msg = sse_init_msg,
        .exe_path = exe_path,
        .exe_mtime = exe_mtime,
        .watch_interval_ns = config.watch_interval_ns,
        .watcher_spawned = std.atomic.Value(bool).init(false),
        .arena = arena,
        .mu = .{},
        .cond = .{},
        .generation = 0,
    };
}

/// Nothing to clean up — all memory is on the server arena.
pub fn deinit(_: *const LiveReload) void {}

// ── Public API ───────────────────────────────────────────────────────────────

/// Signal all connected browsers to reload.
///
/// Use for cases that don't involve a server restart, e.g. a content
/// file changed on disk and the running server already serves the new
/// version.
pub fn reload(self: *LiveReload) void {
    self.mu.lock();
    defer self.mu.unlock();
    self.generation +%= 1;
    self.cond.broadcast();
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
    const owned = self.arena.dupe(u8, dir) catch |err| {
        log.warn("could not allocate watch path for '{s}': {}", .{ dir, err });
        return;
    };
    // Thread is intentionally detached — it runs until process exit.
    _ = std.Thread.spawn(.{}, watchDirLoop, .{ self, owned, opts }) catch |err| {
        log.warn("could not start directory watcher for '{s}': {}", .{ dir, err });
    };
}

fn watchDirLoop(self: *LiveReload, dir: []const u8, opts: WatchDirOpts) void {
    var prev = dirMtime(dir);
    while (true) {
        std.Thread.sleep(opts.poll_ns);
        const curr = dirMtime(dir);
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
fn dirMtime(path: []const u8) i128 {
    var best: i128 = 0;
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return 0;
    defer dir.close();
    walkDirMtime(dir, &best);
    return best;
}

fn walkDirMtime(dir: std.fs.Dir, best: *i128) void {
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                if (stat.mtime > best.*) best.* = stat.mtime;
            },
            .directory => {
                var sub = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub.close();
                walkDirMtime(sub, best);
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
        _ = std.Thread.spawn(.{}, watchBinaryLoop, .{self}) catch {};
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

fn serveSSE(self: *LiveReload, res: *httpz.Response) !void {
    try res.startEventStream(self, sseWriter);
}

/// Runs in a detached thread — no allocator available.
fn sseWriter(self: *LiveReload, stream: std.net.Stream) void {
    stream.writeAll(self.sse_init_msg) catch return;

    // Park until a reload is signalled.
    {
        self.mu.lock();
        defer self.mu.unlock();
        const gen = self.generation;
        while (self.generation == gen) {
            self.cond.wait(&self.mu);
        }
    }

    stream.writeAll(sse_reload) catch {};
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
    while (true) {
        std.Thread.sleep(self.watch_interval_ns);
        const mtime = fileMtime(path);
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

fn fileMtime(path: [:0]const u8) i128 {
    const stat = std.fs.cwd().statFile(path) catch return 0;
    return stat.mtime;
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
        .mu = .{},
        .cond = .{},
        .generation = 0,
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
    try testing.expectEqual(@as(i128, 0), dirMtime("__nonexistent_dir__"));
}

test "dirMtime: returns non-zero for existing directory with files" {
    // Use src/ which always has root.zig
    const mtime = dirMtime("src");
    try testing.expect(mtime > 0);
}

test "WatchDirOpts: defaults" {
    const opts = WatchDirOpts{};
    try testing.expectEqual(@as(u64, 50 * std.time.ns_per_ms), opts.poll_ns);
    try testing.expect(opts.on_change == null);
}
