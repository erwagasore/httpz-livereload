# httpz-livereload

Development-only browser reload middleware for
[httpz](https://github.com/karlseguin/http.zig).

## Compatibility

Requires Zig 0.16.0 or newer and the current httpz API.

## How it works

1. The middleware appends a polling script to buffered HTML responses.
2. Each page contains the server's current version.
3. The script periodically reads the no-store `/_livereload` version endpoint.
4. A new server process starts with a random version, so browsers reload after a
   restart.
5. `reload()` increments the version for changes that do not restart the server,
   such as updated static files.

Chunked, disowned, and already encoded responses are left unchanged. Both
`res.body` and httpz's writer buffer are supported.

## Middleware usage

```zig
const LiveReload = @import("httpz-livereload");

const middleware = try server.middleware(LiveReload, .{});

var router = try server.router(.{ .middlewares = &.{middleware} });
```

### Manual and static-file reloads

A subsystem that owns runtime files should watch those files and signal the
middleware after it has made the new content available:

```zig
const live_reload = LiveReload.from(middleware);

// Direct signal:
live_reload.reload();

// Generic watcher callback, such as httpz-static's:
const watch: Static.Watch = .{
    .context = live_reload,
    .on_change = LiveReload.reloadCallback,
};
```

The next browser poll observes the incremented version and reloads. The server
process does not restart.

## One-command development workflow

Compiled Zig changes require replacing the running executable. The optional
`LiveReload.Supervisor` keeps `zig build run` as the only command developers
need to run:

```zig
pub fn main(init: std.process.Init) !u8 {
    return LiveReload.Supervisor.run(init, .{}, runHttpServer);
}
```

No special build integration is required beyond the usual installed artifact
and run step:

```zig
b.installArtifact(exe);
const run = b.addRunArtifact(exe);
run.step.dependOn(b.getInstallStep());
b.step("run", "Run development server").dependOn(&run.step);
```

The resulting process tree is:

```text
zig build run
└─ supervisor
   ├─ zig build --watch install --prefix .zig-cache/httpz-livereload/install
   └─ .zig-cache/httpz-livereload/install/bin/my-app
```

Zig owns source discovery, filesystem notifications, debouncing, incremental
compilation, and retries after failed builds. The supervisor watches only the
installed executable:

- successful install → stop and replace the server;
- failed build → installed executable remains unchanged and the old server keeps
  serving;
- static/runtime file change → owning subsystem calls `reload()` without a
  restart.

The private install prefix keeps the rebuilt server independent from the outer
`zig build run` artifact. On Windows, the supervisor additionally runs
generation-specific copies so the builder can replace its installed `.exe`
while the old server is running.

`zig build run --watch` is not required and cannot replace this arrangement: a
long-running `run` step prevents Zig's build runner from reaching its own watch
loop. The supervisor instead runs the non-blocking `install` step under
`--watch`.

### Supervisor configuration

Most applications use an empty options struct. Projects with build options pass
them through `build_args`:

```zig
return LiveReload.Supervisor.run(init, .{
    .build_args = &.{"-Dconfig=dev"},
}, runHttpServer);
```

The executable name, builder command, private install prefix, polling interval,
and shutdown policy are derived or fixed internally. Command-line arguments are
forwarded to the server. SIGINT, SIGTERM, and Windows console shutdown stop and
join both children; POSIX shutdown escalates from SIGTERM to SIGKILL after one
second.

## Config

```zig
const middleware = try server.middleware(LiveReload, .{
    .path = "/_livereload",
    .poll_interval_ms = 500,
    .io = init.io,
});
```

`io` is used once to seed the process version. Polling begins only in pages whose
HTML passed through the mounted middleware; omitting the middleware has no
runtime cost.

## Example

```bash
zig build run
# → http://127.0.0.1:3131
```

Edit `example/main.zig`. Zig rebuilds the installed executable, the supervisor
replaces the server, and the browser reloads after observing the new version.

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
const dependency = b.dependency("httpz-livereload", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport(
    "httpz-livereload",
    dependency.module("httpz-livereload"),
);
```

## Architecture

See [SPEC.md](SPEC.md) for the middleware, filesystem-ownership, and supervision
contracts.

## License

MIT
