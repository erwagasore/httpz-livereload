# SPEC — httpz-livereload

Implementation contract for browser reload and minimal development process
supervision for httpz applications.

## Product boundary

The package exposes two independent facilities:

1. `LiveReload` — an httpz middleware that injects a polling client, serves a
   version endpoint, and exposes an in-process reload signal.
2. `LiveReload.Supervisor` — an optional parent process that delegates source
   watching and rebuilding to `zig build --watch install` and replaces the
   server when the installed executable changes.

Mounting the middleware never starts watchers, builders, threads, or child
processes.

## Middleware contract

```zig
const middleware = try server.middleware(LiveReload, .{});
```

### Lifecycle and state

- `Config` contains the version endpoint path, browser polling interval, and the
  `std.Io` used to generate the initial process version.
- `init` copies the path to the server arena and seeds an atomic `u64` version
  with random bytes.
- The middleware has no `deinit`: it owns no detached work or resources outside
  the server arena.
- `reload()` atomically increments the version.
- `from(middleware)` recovers the concrete pointer from httpz's type-erased
  middleware handle.
- `reloadCallback(context)` adapts the handle to generic watcher callback APIs.

### Request behavior

The configured endpoint short-circuits the remaining middleware and returns the
current hexadecimal version as `text/plain` with `Cache-Control: no-store`.

All other requests call `executor.next()` exactly once. After downstream
middleware and the handler return, script injection occurs only when:

- the response has not already been written or switched to chunked transfer;
- the effective content type is HTML, from either `res.content_type == .HTML` or
  a case-insensitive manual `Content-Type: text/html...` header;
- no `Content-Encoding` header is present.

The effective body follows httpz serialization semantics: a non-empty writer
buffer takes precedence over `res.body`. Injection reserves space and appends
directly to a non-empty writer buffer, avoiding a copy of the buffered HTML. A
direct `res.body` is replaced by one exact-size request-arena allocation.
Allocation failure logs a warning and preserves the original response.

### Browser behavior

The script contains the version current when its HTML response was generated.
It polls the configured endpoint with `cache: "no-store"` after each configured
interval. A different successful version response reloads the page. Failed
requests retry without reloading.

A restarted process has a new random version. An in-process `reload()` changes
the current version. Newly loaded pages receive the current version, preventing
reload loops.

## Filesystem ownership

The livereload middleware never watches files.

- Static middleware owns static roots, cache invalidation, and static change
  detection.
- Content subsystems own their source trees and parsed state.
- After making changed runtime content available, an owning subsystem may call
  `LiveReload.reload()`.
- There is one authoritative watcher per filesystem tree.

## Minimal supervisor contract

The parent/child marker remains internal. `Supervisor.run(init, options,
child_main)` invokes `child_main` in marked server children and otherwise runs
the parent supervisor:

```zig
return LiveReload.Supervisor.run(init, .{
    .executable_name = "my-app",
}, runHttpServer);
```

`std.process.Init` supplies the allocator, I/O implementation, environment, and
parent command-line arguments. `executable_name` is the only required option;
`child_args` may override automatic argument forwarding. Normal
`installArtifact` and `addRunArtifact` build integration remains supported.

### Builder ownership

The supervisor starts one persistent builder:

```text
zig build --watch install --prefix .zig-cache/httpz-livereload/install
```

Zig's build runner owns:

- source-input discovery;
- filesystem notifications and debounce;
- incremental compilation;
- serialization of rebuilds;
- recovery after failed builds;
- installation after successful builds.

The supervisor does not accept rebuild paths, restart-only paths, or a custom
builder command. `build_args` appends project-specific `-D` options. A private
install prefix keeps the watched server executable independent from the outer
`zig build run` artifact.

### Replacement behavior

- The supervisor waits for the first successful private installation, then
  starts the server.
- The supervisor fingerprints only that executable.
- A changed fingerprint must remain stable for one polling interval.
- After a stable change, the old server is stopped and joined before the new
  server starts.
- A failed build leaves the installed executable unchanged, so the current
  server continues serving.
- If the server exits independently, its exit code is returned and the builder
  is stopped.
- If the persistent builder exits, its exit code is returned and the server is
  stopped.
- On Windows, each server generation runs from a temporary copy so the builder
  can replace the private installed `.exe` while the old generation runs.

### Shutdown

SIGINT, SIGTERM, and Windows console shutdown request supervisor termination.
Both builder and server children are stopped and joined before `run` returns
`0`. POSIX children receive SIGTERM and are force-killed after
`shutdown_grace_ms`; Windows children are terminated immediately.

The supervisor never calls `std.process.exit`.

## Explicit exclusions

The package does not provide:

- SSE or persistent browser connections;
- file or directory watching in the middleware;
- custom rebuild/restart path classification;
- content parsing or static serving;
- framework-specific HMR;
- browser build-error overlays;
- a general-purpose process supervisor.

## Validation

The project must keep tests for:

- version initialization and explicit reload;
- version endpoint short-circuiting and cache policy;
- direct-body and writer-buffer injection;
- writer-buffer precedence;
- manual HTML content types;
- written, chunked, encoded, and non-HTML pass-through;
- supervisor option validation, child marker, and shutdown state;
- Debug and ReleaseSafe builds;
- the one-command example using the installed executable.
