# Changelog

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
