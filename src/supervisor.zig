//! Minimal development supervisor for `zig build run`.
//!
//! Zig owns source watching, debouncing, incremental compilation, and install
//! semantics through `zig build --watch install`. This supervisor watches only
//! the installed executable and replaces the server after that executable has
//! changed and remained stable for one polling interval.

const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.livereload_supervisor);

const child_marker = "HTTPZ_LIVERELOAD_CHILD";
const default_install_prefix = ".zig-cache/httpz-livereload/install";
const default_poll_interval_ms = 100;
const default_shutdown_grace_ms = 1_000;

/// Development-loop policy. Runtime dependencies come directly from
/// `std.process.Init` so applications only configure project-specific values.
pub const Options = struct {
    /// Filename installed into the private development prefix's `bin` directory.
    /// Windows accepts the name with or without `.exe`.
    executable_name: []const u8,
    /// Arguments passed to the server child. Null forwards the parent process's
    /// arguments after argv[0].
    child_args: ?[]const []const u8 = null,
    /// Additional options passed to `zig build --watch install`.
    build_args: []const []const u8 = &.{},
    /// Private install prefix kept separate from the outer `zig build run`.
    install_prefix: []const u8 = default_install_prefix,
    /// Interval used to observe a stable installed executable.
    poll_interval_ms: u32 = default_poll_interval_ms,
    /// On POSIX, time allowed for a child to exit after SIGTERM before SIGKILL.
    /// Windows children are terminated immediately.
    shutdown_grace_ms: u32 = default_shutdown_grace_ms,
};

const Config = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,
    executable_path: []const u8,
    child_args: []const []const u8,
    builder_argv: []const []const u8,
    poll_interval_ms: u32,
    shutdown_grace_ms: u32,
};

/// Run `child_main` directly in marked server children; otherwise enter the
/// supervised development loop and return the server's final exit code.
pub fn run(
    init: std.process.Init,
    options: Options,
    comptime child_main: fn (std.process.Init) anyerror!void,
) !u8 {
    if (isChild(init.environ_map)) {
        try child_main(init);
        return 0;
    }
    try validate(options);

    const executable_suffix = if (builtin.os.tag == .windows and
        !std.ascii.endsWithIgnoreCase(options.executable_name, ".exe")) ".exe" else "";
    const executable_path = try std.fmt.allocPrint(
        init.gpa,
        "{s}/bin/{s}{s}",
        .{ options.install_prefix, options.executable_name, executable_suffix },
    );
    defer init.gpa.free(executable_path);

    var forwarded_args: std.ArrayList([]const u8) = .empty;
    defer forwarded_args.deinit(init.gpa);
    var args_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args_iterator.deinit();
    _ = args_iterator.skip();
    while (args_iterator.next()) |arg| try forwarded_args.append(init.gpa, arg);
    const child_args = options.child_args orelse forwarded_args.items;

    var builder_argv: std.ArrayList([]const u8) = .empty;
    defer builder_argv.deinit(init.gpa);
    try builder_argv.appendSlice(init.gpa, &.{
        "zig",
        "build",
        "--watch",
        "install",
        "--prefix",
        options.install_prefix,
    });
    try builder_argv.appendSlice(init.gpa, options.build_args);

    return supervise(.{
        .allocator = init.gpa,
        .io = init.io,
        .cwd = .cwd(),
        .env = init.environ_map,
        .executable_path = executable_path,
        .child_args = child_args,
        .builder_argv = builder_argv.items,
        .poll_interval_ms = options.poll_interval_ms,
        .shutdown_grace_ms = options.shutdown_grace_ms,
    });
}

fn isChild(env: *const std.process.Environ.Map) bool {
    return std.mem.eql(u8, env.get(child_marker) orelse return false, "1");
}

fn validate(options: Options) !void {
    if (options.executable_name.len == 0) return error.EmptyExecutableName;
    if (options.install_prefix.len == 0) return error.EmptyInstallPrefix;
    if (options.poll_interval_ms == 0) return error.InvalidPollInterval;
}

/// Run the persistent Zig builder and a marked server child.
fn supervise(config: Config) !u8 {
    var child_env = try config.env.clone(config.allocator);
    defer child_env.deinit();
    try child_env.put(child_marker, "1");

    var shutdown: Shutdown = undefined;
    try shutdown.init();
    defer shutdown.deinit();

    var builder: ManagedChild = .{};
    try builder.start(config, config.builder_argv, config.env);
    defer builder.stop(config);

    var installed = while (true) {
        if (shutdown.isRequested()) return 0;
        if (builder.isDone()) return builder.exitCode();
        break executableFingerprint(config) catch |err| switch (err) {
            error.FileNotFound => {
                try config.io.sleep(
                    .fromMilliseconds(config.poll_interval_ms),
                    .awake,
                );
                continue;
            },
            else => return err,
        };
    };
    var pending: ?u64 = null;
    var generation: u64 = 0;

    replacement: while (true) : (generation +%= 1) {
        const temporary_path: ?[]u8 = if (comptime builtin.os.tag == .windows) blk: {
            const path = try std.fmt.allocPrint(
                config.allocator,
                ".zig-cache/httpz-livereload/child-{d}.exe",
                .{generation},
            );
            errdefer config.allocator.free(path);
            try config.cwd.copyFile(
                config.executable_path,
                config.cwd,
                path,
                config.io,
                .{ .make_path = true },
            );
            break :blk path;
        } else null;
        defer if (temporary_path) |path| {
            config.cwd.deleteFile(config.io, path) catch {};
            config.allocator.free(path);
        };

        const child_executable = temporary_path orelse config.executable_path;
        var child_argv: std.ArrayList([]const u8) = .empty;
        defer child_argv.deinit(config.allocator);
        try child_argv.append(config.allocator, child_executable);
        try child_argv.appendSlice(config.allocator, config.child_args);

        var server: ManagedChild = .{};
        try server.start(config, child_argv.items, &child_env);
        defer server.stop(config);

        while (true) {
            if (shutdown.isRequested()) return 0;

            if (builder.isDone()) {
                const code = builder.exitCode();
                if (!shutdown.isRequested()) {
                    log.err("persistent Zig builder exited with code {d}", .{code});
                }
                return code;
            }

            if (server.isDone()) return server.exitCode();

            try config.io.sleep(
                .fromMilliseconds(config.poll_interval_ms),
                .awake,
            );

            const current = executableFingerprint(config) catch |err| switch (err) {
                // Atomic installation can make the destination briefly absent on
                // some filesystems. Keep serving and inspect it again next tick.
                error.FileNotFound => continue,
                else => return err,
            };

            if (current == installed) {
                pending = null;
                continue;
            }

            if (pending == current) {
                installed = current;
                pending = null;
                log.info("installed executable changed; restarting server", .{});
                server.stop(config);
                continue :replacement;
            }

            pending = current;
        }
    }
}

fn executableFingerprint(config: Config) !u64 {
    const stat = try config.cwd.statFile(config.io, config.executable_path, .{});
    return statFingerprint(stat);
}

fn statFingerprint(stat: std.Io.File.Stat) u64 {
    // Timestamp.nanoseconds is i96 with trailing padding. Widen it before
    // hashing so the padding cannot make an unchanged file appear different.
    const mtime: i128 = stat.mtime.nanoseconds;
    const ctime: i128 = stat.ctime.nanoseconds;

    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&stat.inode));
    hash.update(std.mem.asBytes(&stat.size));
    hash.update(std.mem.asBytes(&mtime));
    hash.update(std.mem.asBytes(&ctime));
    return hash.final();
}

const ChildMonitor = struct {
    done: std.atomic.Value(bool) = .init(false),
    term: std.process.Child.Term = .{ .unknown = 1 },
    wait_failed: bool = false,

    fn wait(self: *ChildMonitor, child: *std.process.Child, io: std.Io) void {
        self.term = child.wait(io) catch {
            self.wait_failed = true;
            self.done.store(true, .release);
            return;
        };
        self.done.store(true, .release);
    }

    fn code(self: *const ChildMonitor) u8 {
        if (self.wait_failed) return 1;
        return switch (self.term) {
            .exited => |exit_code| exit_code,
            else => 1,
        };
    }
};

const ProcessId = if (builtin.os.tag == .windows)
    std.os.windows.DWORD
else
    std.process.Child.Id;

const ManagedChild = struct {
    child: std.process.Child = undefined,
    process_id: ProcessId = undefined,
    monitor: ChildMonitor = .{},
    wait_thread: std.Thread = undefined,
    started: bool = false,
    joined: bool = false,

    fn start(
        self: *ManagedChild,
        config: Config,
        argv: []const []const u8,
        env: *const std.process.Environ.Map,
    ) !void {
        self.* = .{};
        self.child = try std.process.spawn(config.io, .{
            .argv = argv,
            .cwd = .{ .dir = config.cwd },
            .environ_map = env,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
            // Keep every descendant in the child's process group so shutdown
            // cannot orphan Zig's build runner or application workers.
            .pgid = if (comptime builtin.os.tag == .windows) null else 0,
        });
        self.started = true;
        self.process_id = if (comptime builtin.os.tag == .windows) blk: {
            const process_id = GetProcessId(self.child.id.?);
            if (process_id == 0) {
                self.child.kill(config.io);
                self.joined = true;
                return error.ProcessIdUnavailable;
            }
            break :blk process_id;
        } else self.child.id.?;
        self.wait_thread = std.Thread.spawn(
            .{},
            ChildMonitor.wait,
            .{ &self.monitor, &self.child, config.io },
        ) catch |err| {
            // Child.kill waits for termination and releases all child handles.
            // No waiter thread exists on this path.
            self.child.kill(config.io);
            self.joined = true;
            return err;
        };
    }

    fn isDone(self: *const ManagedChild) bool {
        return self.started and self.monitor.done.load(.acquire);
    }

    fn exitCode(self: *ManagedChild) u8 {
        self.join();
        return self.monitor.code();
    }

    fn join(self: *ManagedChild) void {
        if (!self.started or self.joined) return;
        self.wait_thread.join();
        self.joined = true;
    }

    fn stop(self: *ManagedChild, config: Config) void {
        if (!self.started or self.joined) return;
        if (self.isDone()) {
            self.join();
            return;
        }

        requestStop(config, self.process_id) catch |err| {
            log.warn("could not request child shutdown: {}; forcing termination", .{err});
            forceStop(config, self.process_id) catch |force_err| {
                log.err("could not terminate child: {}", .{force_err});
            };
            self.join();
            return;
        };

        const sleep_ms: u32 = 10;
        var remaining = config.shutdown_grace_ms;
        while (remaining > 0 and !self.isDone()) {
            const delay = @min(remaining, sleep_ms);
            config.io.sleep(.fromMilliseconds(delay), .awake) catch break;
            remaining -= delay;
        }

        if (!self.isDone()) {
            log.warn(
                "child did not stop within {d}ms; forcing termination",
                .{config.shutdown_grace_ms},
            );
            forceStop(config, self.process_id) catch |err| {
                log.err("could not terminate child: {}", .{err});
            };
        }
        self.join();
    }
};

fn requestStop(config: Config, process_id: ProcessId) !void {
    if (comptime builtin.os.tag == .windows) return forceStop(config, process_id);
    std.posix.kill(-process_id, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn forceStop(config: Config, process_id: ProcessId) !void {
    if (comptime builtin.os.tag == .windows) {
        var pid_buffer: [32]u8 = undefined;
        const pid = try std.fmt.bufPrint(&pid_buffer, "{d}", .{process_id});
        const result = try std.process.run(config.allocator, config.io, .{
            .argv = &.{ "taskkill", "/F", "/T", "/PID", pid },
            .cwd = .{ .dir = config.cwd },
            .environ_map = config.env,
        });
        defer config.allocator.free(result.stdout);
        defer config.allocator.free(result.stderr);
        return switch (result.term) {
            .exited => |exit_code| if (exit_code == 0) {} else error.ChildTerminationFailed,
            else => error.ChildTerminationFailed,
        };
    }
    std.posix.kill(-process_id, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

const ShutdownState = enum(u8) { inactive, active, requested, closing };

// Signal handlers cannot safely retain a pointer into `run`'s stack. This
// process-lifetime atomic also prevents overlapping supervisors from replacing
// each other's handlers.
var supervisor_shutdown_state: std.atomic.Value(ShutdownState) = .init(.inactive);

const Shutdown = struct {
    old_interrupt: OldAction = undefined,
    old_terminate: OldAction = undefined,

    const OldAction = if (builtin.os.tag == .windows) void else std.posix.Sigaction;

    fn init(self: *Shutdown) !void {
        self.* = .{};
        if (supervisor_shutdown_state.cmpxchgStrong(
            .inactive,
            .active,
            .acq_rel,
            .acquire,
        ) != null) return error.SupervisorAlreadyActive;
        errdefer _ = supervisor_shutdown_state.swap(.inactive, .acq_rel);

        if (comptime builtin.os.tag == .windows) {
            if (SetConsoleCtrlHandler(consoleControlHandler, std.os.windows.BOOL.TRUE) == .FALSE) {
                return error.SignalHandlerUnavailable;
            }
            return;
        }

        const action: std.posix.Sigaction = .{
            .handler = .{ .handler = posixSignalHandler },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.RESTART,
        };
        std.posix.sigaction(.INT, &action, &self.old_interrupt);
        std.posix.sigaction(.TERM, &action, &self.old_terminate);
    }

    fn deinit(self: *Shutdown) void {
        const previous = supervisor_shutdown_state.swap(.closing, .acq_rel);
        std.debug.assert(previous == .active or previous == .requested);

        if (comptime builtin.os.tag == .windows) {
            _ = SetConsoleCtrlHandler(consoleControlHandler, .FALSE);
        } else {
            std.posix.sigaction(.INT, &self.old_interrupt, null);
            std.posix.sigaction(.TERM, &self.old_terminate, null);
        }

        std.debug.assert(supervisor_shutdown_state.swap(.inactive, .acq_rel) == .closing);
        self.* = undefined;
    }

    fn isRequested(_: *const Shutdown) bool {
        return supervisor_shutdown_state.load(.acquire) == .requested;
    }
};

fn requestSupervisorShutdown() void {
    var state = supervisor_shutdown_state.load(.acquire);
    while (state == .active) {
        state = supervisor_shutdown_state.cmpxchgWeak(
            .active,
            .requested,
            .acq_rel,
            .acquire,
        ) orelse return;
    }
}

fn posixSignalHandler(_: std.posix.SIG) callconv(.c) void {
    requestSupervisorShutdown();
}

fn consoleControlHandler(control: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
    return switch (control) {
        0, // CTRL_C_EVENT
        1, // CTRL_BREAK_EVENT
        2, // CTRL_CLOSE_EVENT
        5, // CTRL_LOGOFF_EVENT
        6, // CTRL_SHUTDOWN_EVENT
        => {
            requestSupervisorShutdown();
            return std.os.windows.BOOL.TRUE;
        },
        else => .FALSE,
    };
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const fn (std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn GetProcessId(
    process: std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.DWORD;

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "isChild accepts only the supervisor marker" {
    var env = std.process.Environ.Map.init(testing.allocator);
    defer env.deinit();

    try testing.expect(!isChild(&env));
    try env.put(child_marker, "0");
    try testing.expect(!isChild(&env));
    try env.put(child_marker, "1");
    try testing.expect(isChild(&env));
}

test "options reject empty names prefixes and polling intervals" {
    try testing.expectError(error.EmptyExecutableName, validate(.{
        .executable_name = "",
    }));
    try testing.expectError(error.EmptyInstallPrefix, validate(.{
        .executable_name = "app",
        .install_prefix = "",
    }));
    try testing.expectError(error.InvalidPollInterval, validate(.{
        .executable_name = "app",
        .poll_interval_ms = 0,
    }));
}

test "Shutdown records requests and rejects overlap" {
    {
        var shutdown: Shutdown = undefined;
        try shutdown.init();
        defer shutdown.deinit();

        try testing.expect(!shutdown.isRequested());
        requestSupervisorShutdown();
        try testing.expect(shutdown.isRequested());

        var duplicate: Shutdown = undefined;
        try testing.expectError(error.SupervisorAlreadyActive, duplicate.init());
    }

    requestSupervisorShutdown();
    try testing.expectEqual(ShutdownState.inactive, supervisor_shutdown_state.load(.acquire));
}
