//! Reusable development process supervision for live-reloaded httpz servers.
//!
//! This module is intentionally separate from the middleware contract. It
//! owns file polling, rebuild commands, and child process lifecycle; the root
//! middleware remains an ordinary httpz middleware with `init`, `execute`, and
//! `deinit`.

const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.livereload_supervisor);

pub const child_marker = "HTTPZ_LIVERELOAD_CHILD";
pub const default_poll_interval_ms = 100;
pub const default_debounce_ms = 50;
pub const default_shutdown_grace_ms = 1_000;

pub const Rebuild = struct {
    /// Files and directory trees whose changes require rebuilding the child.
    paths: []const []const u8,
    /// Command executed before starting the replacement child.
    command: []const []const u8 = &.{ "zig", "build" },
};

pub const Config = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    env: *const std.process.Environ.Map,

    /// Arguments after argv[0] passed to each child server.
    child_args: []const []const u8 = &.{},
    /// Executable used for the child. Null resolves the current executable.
    executable_path: ?[]const u8 = null,

    /// Optional rebuild policy. Omit when all watched changes need only restart.
    rebuild: ?Rebuild = null,
    /// Files and directory trees whose changes restart without rebuilding.
    restart_paths: []const []const u8 = &.{},
    /// Filesystem polling interval.
    poll_interval_ms: u32 = default_poll_interval_ms,
    /// Required quiet window after a detected change before taking action.
    debounce_ms: u32 = default_debounce_ms,
    /// On POSIX, time allowed for a child to exit after SIGTERM before SIGKILL.
    /// Windows children are terminated immediately.
    shutdown_grace_ms: u32 = default_shutdown_grace_ms,
};

pub fn isChild(env: *const std.process.Environ.Map) bool {
    const value = env.get(child_marker) orelse return false;
    return std.mem.eql(u8, value, "1");
}

/// Supervise the current application as a marked child until that child exits.
///
/// The caller must check `isChild` before calling `run`; marked children should
/// initialize their httpz server and livereload middleware normally. Child and
/// build stdio are inherited. Rebuilds are transactional: the current child
/// remains available until a replacement build succeeds. A failed build leaves
/// the current child running and waits for another watched change.
pub fn run(config: Config) !u8 {
    var executable_path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const executable_path = config.executable_path orelse blk: {
        const len = try std.process.executablePath(config.io, &executable_path_buffer);
        break :blk executable_path_buffer[0..len];
    };

    var child_env = try config.env.clone(config.allocator);
    defer child_env.deinit();
    try child_env.put(child_marker, "1");

    var child_argv: std.ArrayList([]const u8) = .empty;
    defer child_argv.deinit(config.allocator);
    try child_argv.append(config.allocator, executable_path);
    try child_argv.appendSlice(config.allocator, config.child_args);

    var shutdown: Shutdown = undefined;
    try shutdown.init();
    defer shutdown.deinit();

    var previous = snapshot(config);
    while (true) {
        if (shutdown.isRequested()) return 0;

        var child = try spawn(config, child_argv.items, &child_env);
        const child_id = child.id.?;
        var monitor: ChildMonitor = .{};
        const wait_thread = std.Thread.spawn(.{}, ChildMonitor.wait, .{ &monitor, &child, config.io }) catch |err| {
            child.kill(config.io);
            return err;
        };

        child_lifetime: while (true) {
            const first_change = while (true) {
                if (shutdown.isRequested()) {
                    stopAndJoin(config, child_id, &monitor, wait_thread);
                    return 0;
                }
                if (monitor.done.load(.acquire)) {
                    wait_thread.join();
                    return monitor.exitCode();
                }

                std.Io.sleep(
                    config.io,
                    .fromMilliseconds(config.poll_interval_ms),
                    .awake,
                ) catch |err| {
                    stopAndJoin(config, child_id, &monitor, wait_thread);
                    return err;
                };
                const current = snapshot(config);
                if (current.changeFrom(previous) != null) break current;
            };

            const settled = (settleSnapshot(config, first_change, &shutdown) catch |err| {
                stopAndJoin(config, child_id, &monitor, wait_thread);
                return err;
            }) orelse {
                stopAndJoin(config, child_id, &monitor, wait_thread);
                return 0;
            };
            const change = settled.changeFrom(previous) orelse {
                previous = settled;
                continue :child_lifetime;
            };
            previous = settled;

            switch (change) {
                .rebuild => {
                    const rebuild = config.rebuild.?;
                    while (true) {
                        const build_baseline = previous;
                        log.info("watched source changed; rebuilding replacement", .{});
                        const command_result = runCommand(config, rebuild.command, &shutdown) catch |err| {
                            stopAndJoin(config, child_id, &monitor, wait_thread);
                            return err;
                        };
                        if (command_result == .shutdown) {
                            stopAndJoin(config, child_id, &monitor, wait_thread);
                            return 0;
                        }

                        const after_build = snapshot(config);
                        previous = after_build;

                        if (command_result == .failed) {
                            log.warn("build failed; keeping current child running", .{});
                            if (monitor.done.load(.acquire)) {
                                // The child exited while the build was running.
                                // Re-enter the outer loop so the last known-good
                                // executable is brought back while we wait for
                                // the next source change.
                                wait_thread.join();
                                break :child_lifetime;
                            }
                            // If source changed during the failed build, retry
                            // immediately. A concurrent runtime change must not
                            // disappear into the updated snapshot baseline.
                            if (after_build.changeFrom(build_baseline)) |pending| switch (pending) {
                                .rebuild => continue,
                                .restart => {
                                    log.info("watched runtime files changed; restarting child", .{});
                                    stopAndJoin(config, child_id, &monitor, wait_thread);
                                    break :child_lifetime;
                                },
                            };
                            continue :child_lifetime;
                        }

                        // Never lose edits that arrived while the build was in
                        // progress. Serialize one more build before swapping.
                        if (after_build.rebuild != build_baseline.rebuild) continue;
                        break;
                    }
                    stopAndJoin(config, child_id, &monitor, wait_thread);
                    break :child_lifetime;
                },
                .restart => {
                    log.info("watched runtime files changed; restarting child", .{});
                    stopAndJoin(config, child_id, &monitor, wait_thread);
                    break :child_lifetime;
                },
            }
        }

        // The replacement starts from the complete post-action filesystem.
        previous = snapshot(config);
    }
}

const AtomicBool = std.atomic.Value(bool);
const ActiveRequest = std.atomic.Value(?*AtomicBool);

var active_shutdown_request: ActiveRequest = .init(null);

const Shutdown = struct {
    requested: AtomicBool = .init(false),
    old_interrupt: OldAction = undefined,
    old_terminate: OldAction = undefined,

    const OldAction = if (builtin.os.tag == .windows) void else std.posix.Sigaction;

    fn init(self: *Shutdown) !void {
        self.* = .{};
        if (active_shutdown_request.cmpxchgStrong(
            null,
            &self.requested,
            .acq_rel,
            .acquire,
        ) != null) return error.ShutdownWatcherAlreadyActive;
        errdefer _ = active_shutdown_request.swap(null, .acq_rel);

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
        if (comptime builtin.os.tag == .windows) {
            _ = SetConsoleCtrlHandler(consoleControlHandler, .FALSE);
        } else {
            std.posix.sigaction(.INT, &self.old_interrupt, null);
            std.posix.sigaction(.TERM, &self.old_terminate, null);
        }
        const previous = active_shutdown_request.swap(null, .acq_rel);
        std.debug.assert(previous == &self.requested);
        self.* = undefined;
    }

    fn isRequested(self: *const Shutdown) bool {
        return self.requested.load(.acquire);
    }

    fn request(self: *Shutdown) void {
        self.requested.store(true, .release);
    }
};

fn requestSupervisorShutdown() void {
    const requested = active_shutdown_request.load(.acquire) orelse return;
    requested.store(true, .release);
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

    fn exitCode(self: *const ChildMonitor) u8 {
        if (self.wait_failed) return 1;
        return switch (self.term) {
            .exited => |code| code,
            else => 1,
        };
    }
};

fn spawn(
    config: Config,
    argv: []const []const u8,
    env: *const std.process.Environ.Map,
) !std.process.Child {
    return std.process.spawn(config.io, .{
        .argv = argv,
        .cwd = .{ .dir = config.cwd },
        .environ_map = env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
}

fn stopAndJoin(
    config: Config,
    child_id: std.process.Child.Id,
    monitor: *const ChildMonitor,
    wait_thread: std.Thread,
) void {
    if (monitor.done.load(.acquire)) {
        wait_thread.join();
        return;
    }

    requestStop(child_id) catch |err| {
        log.warn("could not request child shutdown: {}; forcing termination", .{err});
        forceStop(child_id) catch |force_err| {
            log.err("could not terminate child: {}", .{force_err});
        };
        wait_thread.join();
        return;
    };

    const sleep_ms: u32 = 10;
    var remaining = config.shutdown_grace_ms;
    while (remaining > 0 and !monitor.done.load(.acquire)) {
        const delay = @min(remaining, sleep_ms);
        std.Io.sleep(config.io, .fromMilliseconds(delay), .awake) catch break;
        remaining -= delay;
    }

    if (!monitor.done.load(.acquire)) {
        log.warn("child did not stop within {d}ms; forcing termination", .{config.shutdown_grace_ms});
        forceStop(child_id) catch |err| {
            log.err("could not terminate child: {}", .{err});
        };
    }
    wait_thread.join();
}

fn requestStop(child_id: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) return forceStop(child_id);
    std.posix.kill(child_id, .TERM) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

fn forceStop(child_id: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        return switch (std.os.windows.ntdll.NtTerminateProcess(child_id, .SUCCESS)) {
            .SUCCESS, .PROCESS_IS_TERMINATING => {},
            .ACCESS_DENIED => error.AccessDenied,
            else => error.Unexpected,
        };
    }
    std.posix.kill(child_id, .KILL) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => return err,
    };
}

const CommandResult = enum { succeeded, failed, shutdown };

fn runCommand(config: Config, argv: []const []const u8, shutdown: *const Shutdown) !CommandResult {
    var child = try std.process.spawn(config.io, .{
        .argv = argv,
        .cwd = .{ .dir = config.cwd },
        .environ_map = config.env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const child_id = child.id.?;
    var monitor: ChildMonitor = .{};
    const wait_thread = std.Thread.spawn(.{}, ChildMonitor.wait, .{ &monitor, &child, config.io }) catch |err| {
        child.kill(config.io);
        return err;
    };

    while (!monitor.done.load(.acquire)) {
        if (shutdown.isRequested()) {
            stopAndJoin(config, child_id, &monitor, wait_thread);
            return .shutdown;
        }
        try std.Io.sleep(
            config.io,
            .fromMilliseconds(config.poll_interval_ms),
            .awake,
        );
    }
    wait_thread.join();

    if (shutdown.isRequested()) return .shutdown;
    if (monitor.wait_failed) return error.ChildWaitFailed;
    return switch (monitor.term) {
        .exited => |code| if (code == 0) .succeeded else .failed,
        else => .failed,
    };
}

const Change = enum { rebuild, restart };

const Snapshot = struct {
    rebuild: u64,
    restart: u64,

    fn changeFrom(current: Snapshot, previous: Snapshot) ?Change {
        if (current.rebuild != previous.rebuild) return .rebuild;
        if (current.restart != previous.restart) return .restart;
        return null;
    }
};

fn snapshot(config: Config) Snapshot {
    var rebuild: u64 = 0;
    if (config.rebuild) |policy| {
        rebuild = pathsFingerprint(config.io, config.cwd, policy.paths);
    }
    return .{
        .rebuild = rebuild,
        .restart = pathsFingerprint(config.io, config.cwd, config.restart_paths),
    };
}

fn pathsFingerprint(io: std.Io, cwd: std.Io.Dir, paths: []const []const u8) u64 {
    var fingerprint: u64 = 0;
    for (paths) |path| fingerprint +%= pathFingerprint(io, cwd, path);
    return fingerprint;
}

fn settleSnapshot(config: Config, initial: Snapshot, shutdown: *const Shutdown) !?Snapshot {
    if (config.debounce_ms == 0) return initial;

    var settled = initial;
    while (true) {
        if (shutdown.isRequested()) return null;
        try std.Io.sleep(
            config.io,
            .fromMilliseconds(config.debounce_ms),
            .awake,
        );
        const current = snapshot(config);
        if (current.rebuild == settled.rebuild and current.restart == settled.restart) {
            return current;
        }
        settled = current;
    }
}

fn pathFingerprint(io: std.Io, cwd: std.Io.Dir, path: []const u8) u64 {
    var dir = cwd.openDir(io, path, .{ .iterate = true }) catch {
        const stat = cwd.statFile(io, path, .{}) catch return 0;
        return statFingerprint(stat);
    };
    defer dir.close(io);
    return dirFingerprint(io, dir);
}

fn dirFingerprint(io: std.Io, dir: std.Io.Dir) u64 {
    var fingerprint = if (dir.stat(io)) |stat| statFingerprint(stat) else |_| 0;
    var entries = dir.iterate();
    while (entries.next(io) catch null) |entry| {
        var entry_fingerprint = std.hash.Wyhash.hash(0, entry.name);
        switch (entry.kind) {
            .directory => {
                var child = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
                defer child.close(io);
                entry_fingerprint +%= dirFingerprint(io, child);
            },
            else => {
                const stat = dir.statFile(io, entry.name, .{}) catch continue;
                entry_fingerprint +%= statFingerprint(stat);
            },
        }
        // Addition is independent of directory iteration order.
        fingerprint +%= entry_fingerprint;
    }
    return fingerprint;
}

fn statFingerprint(stat: std.Io.File.Stat) u64 {
    // Timestamp.nanoseconds is i96 and has undefined trailing padding in its
    // in-memory representation. Widen before hashing so snapshots never hash
    // indeterminate bytes.
    const mtime: i128 = stat.mtime.nanoseconds;
    const ctime: i128 = stat.ctime.nanoseconds;

    var hash = std.hash.Wyhash.init(0);
    hash.update(std.mem.asBytes(&stat.inode));
    hash.update(std.mem.asBytes(&stat.size));
    hash.update(std.mem.asBytes(&mtime));
    hash.update(std.mem.asBytes(&ctime));
    return hash.final();
}

test "isChild accepts only the supervisor marker" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    try std.testing.expect(!isChild(&env));
    try env.put(child_marker, "0");
    try std.testing.expect(!isChild(&env));
    try env.put(child_marker, "1");
    try std.testing.expect(isChild(&env));
}

test "Shutdown records programmatic and platform-handler requests" {
    var shutdown: Shutdown = undefined;
    try shutdown.init();
    defer shutdown.deinit();

    try std.testing.expect(!shutdown.isRequested());
    shutdown.request();
    try std.testing.expect(shutdown.isRequested());

    shutdown.requested.store(false, .release);
    if (comptime builtin.os.tag == .windows) {
        try std.testing.expect(consoleControlHandler(0) == std.os.windows.BOOL.TRUE);
    } else {
        posixSignalHandler(.TERM);
    }
    try std.testing.expect(shutdown.isRequested());
}

test "Snapshot prioritizes rebuild changes" {
    const previous: Snapshot = .{ .rebuild = 1, .restart = 2 };
    try std.testing.expectEqual(Change.rebuild, Snapshot.changeFrom(.{ .rebuild = 3, .restart = 4 }, previous).?);
    try std.testing.expectEqual(Change.restart, Snapshot.changeFrom(.{ .rebuild = 1, .restart = 4 }, previous).?);
    try std.testing.expect(Snapshot.changeFrom(previous, previous) == null);
}

test "snapshot is stable without filesystem changes" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    const config: Config = .{
        .allocator = std.testing.allocator,
        .io = std.Options.debug_io,
        .cwd = .cwd(),
        .env = &env,
        .rebuild = .{ .paths = &.{"src"} },
        .restart_paths = &.{"docs"},
    };
    const first = snapshot(config);
    const second = snapshot(config);
    try std.testing.expectEqual(first.rebuild, second.rebuild);
    try std.testing.expectEqual(first.restart, second.restart);
}
