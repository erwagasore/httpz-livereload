# Changelog

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
