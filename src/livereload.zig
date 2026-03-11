//! httpz-livereload — browser reload middleware for httpz.
//!
//! Injects a tiny script into HTML responses that detects server restarts
//! and reloads the page. Supports three complementary mechanisms:
//!
//! 1. **Restart detection** — each server instance has a unique ID. When the
//!    browser's SSE connection drops (process killed) and reconnects to a new
//!    server, the ID mismatch triggers a reload. Works with `watchexec` or
//!    any process manager.
//!
//! 2. **Binary self-watch** — a background thread monitors the server
//!    executable on disk. When it changes (e.g. `zig build --watch` rebuilt
//!    it), the middleware signals all browsers to reload, then exits the
//!    process so it can restart with new code. Pair with a restart wrapper:
//!
//!    ```sh
//!    # Terminal 1
//!    zig build --watch
//!
//!    # Terminal 2
//!    while zig-out/bin/server; do sleep 0.1; done
//!    ```
//!
//! 3. **Manual reload** — call `reloader.reload()` from application code to
//!    trigger a browser reload without restarting (e.g. content file changes).
//!
//! ## Usage
//!
//! ```zig
//! const LiveReload = @import("httpz-livereload");
//! const livereload = try server.middleware(LiveReload, .{});
//! var r = try server.router(.{ .middlewares = &.{ livereload } });
//! ```

const std = @import("std");
const httpz = @import("httpz");

const LiveReload = @This();

// ── Reloader ─────────────────────────────────────────────────────────────────

/// Thread-safe handle to trigger browser reloads from application code.
pub const Reloader = struct {
    mu: *std.Thread.Mutex,
    cond: *std.Thread.Condition,
    generation: *u64,

    /// Signal all connected browsers to reload.
    pub fn reload(self: Reloader) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.generation.* +%= 1;
        self.cond.broadcast();
    }
};

// ── Config ───────────────────────────────────────────────────────────────────

pub const Config = struct {
    /// SSE endpoint path. Default: `/_livereload`.
    path: []const u8 = "/_livereload",

    /// Watch the server binary for changes. When a change is detected,
    /// all connected browsers are signalled to reload and the process
    /// exits (code 0) so a wrapper can restart it with new code.
    /// Default: true.
    watch: bool = true,

    /// How often to check the binary for changes (nanoseconds).
    /// Default: 500ms.
    watch_interval_ns: u64 = 500 * std.time.ns_per_ms,
};

// ── State ────────────────────────────────────────────────────────────────────

path: []const u8,
server_id: []const u8,
inject_snippet: []const u8,
mu: std.Thread.Mutex,
cond: std.Thread.Condition,
generation: u64,

// Binary watcher state (set once in init, thread spawned on first request).
exe_path: ?[:0]const u8,
exe_mtime: i128,
watch_interval_ns: u64,
watcher_started: std.atomic.Value(bool),

pub fn init(config: Config, mw_config: httpz.MiddlewareConfig) !LiveReload {
    const arena = mw_config.arena;

    const server_id = try std.fmt.allocPrint(arena, "{d}", .{std.time.milliTimestamp()});

    const inject_snippet = try std.fmt.allocPrint(arena,
        \\<script>(function(){{var id=null,s=new EventSource("{s}");
        \\s.addEventListener("init",function(e){{if(id!==null&&id!==e.data){{s.close();location.reload()}}id=e.data}});
        \\s.addEventListener("reload",function(){{s.close();location.reload()}})}})()</script>
    , .{config.path});

    // Resolve executable path and initial mtime for the binary watcher.
    var exe_path: ?[:0]const u8 = null;
    var exe_mtime: i128 = 0;
    if (config.watch) {
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (std.fs.selfExePath(&exe_buf)) |p| {
            exe_path = try arena.dupeZ(u8, p);
            exe_mtime = fileMtime(exe_path.?);
        } else |_| {}
    }

    return .{
        .path = config.path,
        .server_id = server_id,
        .inject_snippet = inject_snippet,
        .mu = .{},
        .cond = .{},
        .generation = 0,
        .exe_path = exe_path,
        .exe_mtime = exe_mtime,
        .watch_interval_ns = config.watch_interval_ns,
        .watcher_started = std.atomic.Value(bool).init(false),
    };
}

/// Return a `Reloader` handle for triggering manual browser reloads.
pub fn reloader(self: *LiveReload) Reloader {
    return .{
        .mu = &self.mu,
        .cond = &self.cond,
        .generation = &self.generation,
    };
}

// ── Middleware execute ────────────────────────────────────────────────────────

pub fn execute(self: *LiveReload, req: *httpz.Request, res: *httpz.Response, executor: anytype) !void {
    // Lazily spawn the binary watcher on first request. At this point `self`
    // is the arena-allocated pointer that will live for the process lifetime.
    if (self.exe_path != null and
        self.watcher_started.cmpxchgStrong(false, true, .seq_cst, .seq_cst) == null)
    {
        _ = std.Thread.spawn(.{}, watchBinaryLoop, .{self}) catch {};
    }

    // ── SSE endpoint ─────────────────────────────────────────────────────
    if (std.mem.eql(u8, req.url.path, self.path)) {
        return self.handleSSE(res);
    }

    // ── Normal request — run the handler chain ───────────────────────────
    try executor.next();

    // ── Inject script into HTML responses ────────────────────────────────
    if (res.content_type == .HTML) {
        self.injectScript(res);
    }
}

// ── SSE handler ──────────────────────────────────────────────────────────────

const SSECtx = struct {
    livereload: *LiveReload,
};

fn handleSSE(self: *LiveReload, res: *httpz.Response) !void {
    const ctx = SSECtx{ .livereload = self };
    try res.startEventStream(ctx, sseHandler);
}

fn sseHandler(ctx: SSECtx, stream: std.net.Stream) void {
    const self = ctx.livereload;

    // Send init event with server ID.
    const init_msg = std.fmt.allocPrint(
        std.heap.page_allocator,
        "retry:2000\nevent:init\ndata:{s}\n\n",
        .{self.server_id},
    ) catch return;
    defer std.heap.page_allocator.free(init_msg);

    stream.writeAll(init_msg) catch return;

    // Hold the connection open — wait for a reload signal.
    self.mu.lock();
    const gen = self.generation;
    while (self.generation == gen) {
        self.cond.wait(&self.mu);
    }
    self.mu.unlock();

    // Reload triggered — send reload event and close.
    stream.writeAll("event:reload\ndata:\n\n") catch {};
}

// ── Script injection ─────────────────────────────────────────────────────────

fn injectScript(self: *LiveReload, res: *httpz.Response) void {
    if (res.body.len > 0) {
        const new_body = std.fmt.allocPrint(
            res.arena,
            "{s}{s}",
            .{ res.body, self.inject_snippet },
        ) catch return;
        res.body = new_body;
    } else {
        res.writer().writeAll(self.inject_snippet) catch {};
    }
}

// ── Binary watcher ───────────────────────────────────────────────────────────

fn watchBinaryLoop(self: *LiveReload) void {
    const path = self.exe_path orelse return;
    while (true) {
        std.Thread.sleep(self.watch_interval_ns);
        const mtime = fileMtime(path);
        if (mtime != self.exe_mtime) {
            // Binary changed — signal browsers and exit.
            self.reloader().reload();
            // Give SSE threads time to flush the reload event.
            std.Thread.sleep(300 * std.time.ns_per_ms);
            std.process.exit(0);
        }
    }
}

fn fileMtime(path: [:0]const u8) i128 {
    const stat = std.fs.cwd().statFile(path) catch return 0;
    return stat.mtime;
}

// ── Tests ────────────────────────────────────────────────────────────────────

test "reloader changes generation" {
    var mu: std.Thread.Mutex = .{};
    var cond: std.Thread.Condition = .{};
    var generation: u64 = 0;

    const r = Reloader{ .mu = &mu, .cond = &cond, .generation = &generation };
    r.reload();
    try std.testing.expectEqual(@as(u64, 1), generation);
    r.reload();
    try std.testing.expectEqual(@as(u64, 2), generation);
}

test {
    std.testing.refAllDecls(@This());
}
