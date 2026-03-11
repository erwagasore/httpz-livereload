# httpz-livereload

Browser reload middleware for [httpz](https://github.com/karlseguin/http.zig).

Inspired by [tower-livereload](https://github.com/leotaku/tower-livereload).

## How it works

1. HTML responses get a `<script>` appended that opens an
   [EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource)
   to `/_livereload`.
2. The SSE endpoint sends `event: init` with a unique server ID, then holds
   the connection open.
3. The middleware detects restarts two ways:
   - **Process restart**: SSE connections drop. The browser reconnects, sees a
     new server ID, and reloads.
   - **Binary change**: a background thread watches the server executable on
     disk. When it changes, all browsers are signalled to reload and the
     process exits so it can restart with new code.
4. For explicit reloads without restart (e.g. content file changes), call
   `reload()` from application code.

## Usage

```zig
const LiveReload = @import("httpz-livereload");

// Create the middleware
const livereload = try server.middleware(LiveReload, .{});

// Add to your middleware chain
var r = try server.router(.{ .middlewares = &.{ livereload } });
```

## Dev workflows

### `zig build --watch` + restart loop

No extra tools needed. The binary watcher detects rebuilds and exits the
server so the loop restarts it:

```bash
# Terminal 1 — continuously recompile
zig build --watch

# Terminal 2 — run server, restart on exit
while zig-out/bin/server; do sleep 0.1; done
```

### watchexec (single terminal)

```bash
watchexec -r -e zig,md,css,js -- zig build run
```

### Manual reload

Trigger browser reloads from application code without restarting:

```zig
const livereload = try server.middleware(LiveReload, .{});
const lr = LiveReload.from(livereload);

// Later, from a file watcher or other trigger:
lr.reload();  // all connected browsers reload
```

## Config

```zig
const livereload = try server.middleware(LiveReload, .{
    .path = "/_livereload",        // SSE endpoint path
    .watch = true,                 // watch own binary for changes
    .watch_interval_ns = 500_000_000,  // check every 500ms
});
```

Set `.watch = false` to disable the binary watcher (e.g. when using
`watchexec` which handles restarts itself).

## Example

```bash
# Build and run the example server
zig build run
# → http://127.0.0.1:3131

# Or with zig build --watch:
zig build --watch &
while zig-out/bin/example; do sleep 0.1; done
```

## Install

Add to `build.zig.zon`:

```zig
.@"httpz-livereload" = .{
    .url = "git+https://github.com/erwagasore/httpz-livereload.git?ref=main#COMMIT",
    .hash = "...",
},
```

Add to `build.zig`:

```zig
const livereload_dep = b.dependency("httpz-livereload", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("httpz-livereload", livereload_dep.module("httpz-livereload"));
```

## How it compares to tower-livereload

Same pattern, adapted for Zig and httpz:

| | tower-livereload (Rust) | httpz-livereload (Zig) |
|---|---|---|
| Framework | tower / axum / hyper | httpz |
| SSE mechanism | Async streaming body | `res.startEventStream` (thread per SSE) |
| Script injection | Response body wrapper | Append to `res.body` / writer in middleware |
| Restart detection | SSE connection drop + reconnect | SSE reconnect + binary self-watch |
| Manual reload | `Reloader::reload()` via `tokio::Notify` | `lr.reload()` via Mutex + Condition |
| Heuristic | `Content-Type: text/html` | `res.content_type == .HTML` |

## License

MIT
