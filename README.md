# httpz-livereload

Browser reload middleware for [httpz](https://github.com/karlseguin/http.zig).

Inspired by [tower-livereload](https://github.com/leotaku/tower-livereload).

## Compatibility

Requires Zig 0.16.0 or newer and the current httpz API.

## How it works

1. HTML responses get a `<script>` appended that opens an
   [EventSource](https://developer.mozilla.org/en-US/docs/Web/API/EventSource)
   to `/_livereload`.
2. The SSE endpoint sends `event: init`, then holds the connection open.
3. When the server restarts, SSE connections drop. The browser reconnects,
   sees a new `init` event, and reloads.
4. For explicit reloads without restart (e.g. content file changes), call
   `reload()` from application code.

The middleware never rebuilds, restarts, or exits the host process. Applications
that reload compiled code should put that policy in a development supervisor.

## Usage

```zig
const LiveReload = @import("httpz-livereload");

// Create the middleware. In Zig 0.16, pass `init.io` from
// `pub fn main(init: std.process.Init) !void`.
const livereload = try server.middleware(LiveReload, .{ .io = init.io });

// Add to your middleware chain
var r = try server.router(.{ .middlewares = &.{ livereload } });
```

## Dev workflows

Rebuilding Zig source requires a process supervisor: the running program cannot
load newly compiled code into itself. `LiveReload.Supervisor` provides that
capability separately from the middleware contract.

At application startup, marked children run the HTTP server normally; the
unmarked parent configures and runs the supervisor:

```zig
if (LiveReload.Supervisor.isChild(init.environ_map)) {
    return runHttpServer(init);
}

return LiveReload.Supervisor.run(.{
    .allocator = init.gpa,
    .io = init.io,
    .cwd = .cwd(),
    .env = init.environ_map,
    // Required when the parent was launched by `zig build run`, whose running
    // artifact is not the installed replacement produced by the nested build.
    .executable_path = "zig-out/bin/my-app",
    .rebuild = .{
        .paths = &.{ "src", "build.zig", "build.zig.zon" },
    },
    .restart_paths = &.{"configuration"},
});
```

The supervisor polls watched paths (100ms by default), debounces change batches
for 50ms, and inherits child/build stdio. It returns the final child exit code
when the child exits independently. On SIGINT, SIGTERM, or a Windows console
shutdown event, the supervisor stops and joins any active build and server child,
then returns `0`. On POSIX, children receive SIGTERM and are sent SIGKILL after
one second by default; configure this with `shutdown_grace_ms`. Windows children
are terminated immediately.
Rebuilds are transactional: the current child keeps serving while the replacement
build runs, failed builds leave it untouched, and edits arriving during a build
schedule another serialized build before the child is swapped. It never invokes
`process.exit()`.

Use `rebuild.paths` only for compiled inputs and `restart_paths` for changes
that require reconstructing process state. The subsystem that owns runtime
files should own their watcher and call `reload()` when those files change. For
example, a static-file middleware can invalidate its cache and signal the
livereload handle from one authoritative watcher.

Alternatively, applications can use an external supervisor:

```bash
watchexec -r -e zig,md,css,js -- zig build run
```

### Manual reload

Trigger browser reloads from application code without restarting:

```zig
const livereload = try server.middleware(LiveReload, .{ .io = init.io });
const lr = LiveReload.from(livereload);

// Later, from a file watcher or other trigger:
lr.reload();  // all connected browsers reload
```

## Config

```zig
const livereload = try server.middleware(LiveReload, .{
    .path = "/_livereload",  // SSE endpoint path
    .retry_ms = 50,          // browser reconnect interval (ms)
    .io = init.io,           // Zig 0.16 I/O implementation
});
```

## Example

```bash
# Either form supports supervised rebuilds.
zig build run
# or: zig build && ./zig-out/bin/example
# → http://127.0.0.1:3131
```

## Install

Add to `build.zig.zon`:

```zig
.@"httpz-livereload" = .{
    .url = "git+https://github.com/erwagasore/httpz-livereload#COMMIT",
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
| Restart detection | SSE connection drop + reconnect | SSE connection drop + reconnect |
| Manual reload | `Reloader::reload()` via `tokio::Notify` | `lr.reload()` via Mutex + Condition |
| Heuristic | `Content-Type: text/html` | `res.content_type == .HTML` |

## Architecture

See [SPEC.md](SPEC.md) for the middleware, filesystem-ownership, supervision,
and teardown contracts.

## License

MIT
