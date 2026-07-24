const std = @import("std");
const httpz = @import("httpz");
const LiveReload = @import("httpz-livereload");

pub fn main(init: std.process.Init) !u8 {
    return LiveReload.Supervisor.run(init, .{
        .executable_name = "example",
    }, runServer);
}

fn runServer(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(3131),
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    const livereload = try server.middleware(LiveReload, .{});

    var router = try server.router(.{ .middlewares = &.{livereload} });
    router.get("/", index, .{});

    std.log.info("listening on http://127.0.0.1:3131", .{});
    try server.listen();
}

fn index(_: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .HTML;
    res.body =
        \\<!doctype html>
        \\<html><head><title>httpz-livereload example</title></head>
        \\<body>
        \\<h1>Hello from httpz-livereload</h1>
        \\<p>Edit this file and save — the supervisor rebuilds and the browser reloads.</p>
        \\</body></html>
    ;
}
