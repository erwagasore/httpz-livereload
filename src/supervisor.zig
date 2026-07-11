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

    var previous = snapshot(config);
    while (true) {
        var child = try spawn(config, child_argv.items, &child_env);
        const child_id = child.id.?;
        var monitor: ChildMonitor = .{};
        const wait_thread = std.Thread.spawn(.{}, ChildMonitor.wait, .{ &monitor, &child, config.io }) catch |err| {
            child.kill(config.io);
            return err;
        };

        child_lifetime: while (true) {
            const first_change = while (!monitor.done.load(.acquire)) {
                std.Io.sleep(
                    config.io,
                    .fromMilliseconds(config.poll_interval_ms),
                    .awake,
                ) catch |err| {
                    requestStop(child_id);
                    wait_thread.join();
                    return err;
                };
                const current = snapshot(config);
                if (current.changeFrom(previous) != null) break current;
            } else {
                wait_thread.join();
                return monitor.exitCode();
            };

            const settled = settleSnapshot(config, first_change) catch |err| {
                requestStop(child_id);
                wait_thread.join();
                return err;
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
                        const succeeded = runCommand(config, rebuild.command) catch |err| {
                            requestStop(child_id);
                            wait_thread.join();
                            return err;
                        };
                        const after_build = snapshot(config);
                        previous = after_build;

                        if (!succeeded) {
                            log.warn("build failed; keeping current child running", .{});
                            if (monitor.done.load(.acquire)) {
                                wait_thread.join();
                                return monitor.exitCode();
                            }
                            // If source changed during the failed build, retry
                            // immediately; otherwise wait for the next edit.
                            if (after_build.rebuild != build_baseline.rebuild) continue;
                            continue :child_lifetime;
                        }

                        // Never lose edits that arrived while the build was in
                        // progress. Serialize one more build before swapping.
                        if (after_build.rebuild != build_baseline.rebuild) continue;
                        break;
                    }
                    requestStop(child_id);
                    wait_thread.join();
                    break :child_lifetime;
                },
                .restart => {
                    log.info("watched runtime files changed; restarting child", .{});
                    requestStop(child_id);
                    wait_thread.join();
                    break :child_lifetime;
                },
            }
        }

        // The replacement starts from the complete post-action filesystem.
        previous = snapshot(config);
    }
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

fn requestStop(child_id: std.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) {
        _ = std.os.windows.ntdll.NtTerminateProcess(child_id, .SUCCESS);
    } else {
        std.posix.kill(child_id, .TERM) catch |err| switch (err) {
            error.ProcessNotFound => {},
            else => {},
        };
    }
}

fn runCommand(config: Config, argv: []const []const u8) !bool {
    var child = try std.process.spawn(config.io, .{
        .argv = argv,
        .cwd = .{ .dir = config.cwd },
        .environ_map = config.env,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    });
    const term = try child.wait(config.io);
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
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

fn settleSnapshot(config: Config, initial: Snapshot) !Snapshot {
    if (config.debounce_ms == 0) return initial;

    var settled = initial;
    while (true) {
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
