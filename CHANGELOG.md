# Changelog

## [0.4.7] — 2026-03-12

### Fixes

- Revert to fixed-interval probe on the SSE endpoint (`/_livereload`).
  The exponential backoff and `fetch('/')` probe introduced in v0.4.3–v0.4.6
  caused cached responses to trigger premature reloads with broken CSS.
  SSE responses are not cacheable, so probing the SSE endpoint directly
  is reliable.

## [0.4.6] — 2026-03-12

### Fixes

- Set `Cache-Control: no-cache, no-store, must-revalidate` on all HTML
  responses in dev mode. Prevents `location.reload()` from serving stale
  HTML and CSS from browser cache after a server restart.

## [0.4.5] — 2026-03-12

### Fixes

- Bypass browser cache on reconnection probe (`cache: 'no-store'`).
  Without this, `fetch('/')` could resolve from cache while the server
  was still down, causing a premature reload with broken CSS/JS.

## [0.4.4] — 2026-03-12

### Other

- Start reconnection probe at 1s (was `retry_ms` / 50ms) and raise the
  backoff cap to 4s — reduces noise in the browser network tab while the
  server is down without noticeably affecting reload speed.

## [0.4.3] — 2026-03-12

### Fixes

- Use exponential backoff for the `fetch()` reconnection probe — starts
  at `retry_ms` and doubles up to a 2s cap, reducing unnecessary network
  churn when the server is down for longer periods.

## [0.4.2] — 2026-03-12

### Fixes

- Close EventSource on `beforeunload` to prevent browser console errors
  when navigating away from a page with an active SSE connection.
- Probe the root URL (`/`) instead of the SSE endpoint for reconnection —
  avoids spawning an orphaned `sseWriter` thread on each fetch probe.

## [0.4.1] — 2026-03-12

### Fixes

- Prevent duplicate SSE connections on SPA-style navigation by guarding
  against re-injection with `window.__lr`.
- Use allocation-free manual recursion in `dirMtime` instead of
  `std.fs.Dir.walk()` for thread safety — avoids sharing a non-thread-safe
  arena allocator across concurrent watcher threads.

### Other

- Use `fetch()` probe for reconnection instead of re-creating EventSource —
  fails instantly on connection refused (~1ms vs 2-3s stall in Firefox).
- Lower default poll intervals: binary watcher 500ms → 50ms, directory
  watcher 100ms → 50ms, post-reload exit delay 300ms → 50ms.
- Drop explicit debounce in directory watcher — at 50ms poll, rapid writes
  coalesce naturally.
- Bundle `on_change` callback and context into a single `OnChangeFn` struct;
  remove dead `t` variable from injected JavaScript.

## [0.4.0] — 2026-03-12

### Features

- **Directory watching** — new `watchDir()` method lets you watch
  directory trees for file changes. On change, an optional callback is
  invoked (e.g. to re-parse content), then all connected browsers are
  signalled to reload. Default poll interval is 100ms (configurable via
  `poll_ns`). Each call spawns a lightweight background thread.

## [0.3.0] — 2026-03-12

### Features

- **Aggressive reconnection** — the client script now bypasses
  EventSource's built-in retry and re-creates the connection after a
  short `setTimeout`. This eliminates the overhead of the browser's
  internal retry machinery and makes reconnects near-instant.
- Default `retry_ms` lowered from 200ms to **50ms**. With the custom
  reconnect handler, the cost of a few extra TCP SYN+RST rounds on
  localhost is negligible.

## [0.2.0] — 2026-03-12

### Features

- Configurable `retry_ms` for the EventSource reconnection interval
  (default: 200ms, previously hardcoded at 2000ms). Lower values mean
  faster browser reload after a server restart.

## [0.1.0] — 2026-03-11

Initial release.

### Features

- SSE-based browser reload middleware for httpz
- Automatic `<script>` injection into HTML responses
- Binary self-watch with configurable polling interval
- Manual reload API via `LiveReload.from(mw).reload()`
- Reconnection-based restart detection (SSE drop + reconnect)
- Configurable SSE endpoint path

### Other

- Align with httpz middleware conventions (`root.zig`, `*const` deinit)
- Documentation and example server
