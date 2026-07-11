# SPEC — httpz-livereload

Implementation contract for browser reload transport and optional development
process supervision for httpz applications.

## Product boundary

`httpz-livereload` exposes two independent facilities:

1. `LiveReload` — an ordinary httpz middleware that injects a browser client,
   serves an SSE endpoint, and signals reloads.
2. `LiveReload.Supervisor` — an opt-in development process supervisor that
   watches application-owned paths, rebuilds compiled inputs, and replaces a
   child server.

Importing or mounting the middleware never starts the supervisor. Applications
that only need browser reload transport pay no process-supervision wiring cost.

## Middleware contract

The root module remains directly mountable with httpz:

```zig
const livereload = try server.middleware(LiveReload, .{ .io = init.io });
const router = try server.router(.{ .middlewares = &.{livereload} });
```

It follows httpz's middleware lifecycle exactly:

- `Config` contains middleware-only settings: SSE `path`, browser `retry_ms`,
  and the explicit `std.Io` used for synchronization.
- `init(Config, httpz.MiddlewareConfig)` allocates immutable path/script/SSE
  bytes from the server arena and returns the middleware value.
- `execute` short-circuits the configured SSE route; otherwise it calls
  `executor.next()` once and injects only into HTML responses afterward.
- `deinit` wakes active SSE writers and waits for them before httpz releases the
  server arena.

The middleware never watches files, serves static files, rebuilds, restarts,
spawns, or exits processes. It never calls `std.process.exit`.

### Browser reload behavior

- The injected script opens an `EventSource` to the configured path.
- A new connection receives `event: init`.
- Reconnection after a server restart causes a browser reload.
- `reload()` broadcasts `event: reload` to connected clients.
- `from(middleware)` returns the concrete reload handle from httpz's type-erased
  middleware handle for explicit application integration.

### SSE ownership and teardown

SSE writers run in httpz-managed detached threads and borrow middleware-owned
arena slices. `serveSSE` reserves an active-writer slot before asking httpz to
spawn the writer. Spawn failure releases the reservation. The writer releases
it on every return path. `deinit` sets `stopping`, broadcasts the condition, and
waits until all reservations are released. This startup handshake prevents
teardown from missing a spawned-but-not-yet-scheduled writer and freeing its
borrowed arena first.

## Filesystem ownership and middleware composition

A subsystem that owns files owns their watcher:

- A future `httpz-static` owns static file serving, cache invalidation, and its
  static-root watcher.
- A content subsystem owns content parsing/cache invalidation and its watcher.
- Those subsystems remain independent of `httpz-livereload` and expose generic
  change callbacks or events.
- Applications may connect those events to `LiveReload.reload()`.

There must be only one authoritative watcher per filesystem tree. The
livereload middleware does not duplicate watchers owned by static/content
middleware and does not depend on those packages.

## Supervisor contract

`LiveReload.Supervisor` is separate from the middleware lifecycle. The caller
checks `Supervisor.isChild(env)` before deciding whether to run the HTTP server
or the parent supervisor.

`Supervisor.Config` receives explicit runtime dependencies and policy:

- allocator, `std.Io`, working directory, and environment;
- optional child executable and child arguments; applications launched through
  `zig build run` set the executable to their installed `zig-out/bin/...` path
  because the running cache artifact is not replaced by a nested build;
- optional rebuild paths and rebuild command; the default is `zig build` and
  works both directly and under an enclosing `zig build run`;
- restart-only paths;
- polling, debounce, and child shutdown grace intervals.

The supervisor clones the environment, adds its internal child marker, inherits
child/build stdio, and returns the final child exit code. It never calls
`std.process.exit`.

### Change actions

- **Rebuild paths** identify compiled inputs. Their changes run the configured
  build command and replace the child only after success.
- **Restart paths** identify runtime inputs that require process-state
  reconstruction but no build.
- Reload-only runtime files do not belong in supervisor policy when their
  owning subsystem can reread them; that subsystem signals `reload()` directly.

### Transactional rebuild semantics

- Filesystem changes settle for the configured debounce window.
- Only one build/restart action runs at a time.
- The current child continues serving while a replacement build runs.
- A failed build leaves the current child running.
- A change observed during a build schedules another serialized build before
  the child is replaced.
- Once a stable build succeeds, the supervisor stops and joins the old child,
  then starts the replacement.
- On POSIX, child shutdown escalates from SIGTERM to SIGKILL after the
  configured grace interval. Windows children are terminated immediately.

These rules minimize browser downtime and prevent half-written editor saves or
concurrent rebuilds from producing inconsistent replacement processes.

## API ergonomics

- Middleware registration remains one normal `server.middleware` call.
- Supervisor setup occurs once per application, never once per middleware.
- Middleware packages do not acquire hidden global process or filesystem
  ownership.
- Runtime dependencies and watched paths remain explicit and testable.
- An external supervisor such as `watchexec` remains supported; applications
  can mount only the middleware and omit `Supervisor` entirely.

## Out of scope

- Static file serving and cache policy.
- Content parsing or cache ownership.
- Framework-specific HMR/module replacement.
- Browser build-error overlays.
- A global event bus shared implicitly by unrelated middleware.

## Validation

The project must keep:

- middleware init/injection/pass-through tests;
- SSE reservation and teardown regression coverage;
- supervisor marker, snapshot priority, and snapshot stability tests;
- Debug and ReleaseSafe test builds;
- an example that mounts the middleware normally, opts into the supervisor at
  the application boundary, and works both directly and through `zig build run`.
