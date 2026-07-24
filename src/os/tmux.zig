//! Locate and drive the tmux server whose client is attached to a given
//! tty. The terminal owns the pty, so the tty name uniquely identifies
//! the tmux client running inside a surface; matching it against
//! `list-clients` yields both the server socket and the session to
//! target, without any tmux-side configuration.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const path = @import("path.zig");

const log = std.log.scoped(.@"os-tmux");

/// Run a tmux command against the session whose client is attached to
/// the given tty. Returns true if a command was executed successfully
/// and false if no tmux client is attached to the tty, tmux is not
/// installed, or the command failed.
///
/// The tmux command is tokenized with shell-like quoting but without
/// any expansion. Unless the command already carries a `-t` target,
/// the matched session id is appended as `-t <session>` so the command
/// acts on the session visible in this terminal.
///
/// The allocator should be an arena: this function makes no attempt to
/// free intermediate allocations.
pub fn sessionCommand(
    alloc: Allocator,
    tty_name: []const u8,
    command: []const u8,
) !bool {
    return switch (builtin.os.tag) {
        .linux, .freebsd, .macos => sessionCommandPosix(alloc, tty_name, command),
        else => false,
    };
}

fn sessionCommandPosix(
    alloc: Allocator,
    tty_name: []const u8,
    command: []const u8,
) !bool {
    const args = try splitArgs(alloc, command);
    if (args.len == 0) {
        log.warn("tmux command is empty, ignoring", .{});
        return false;
    }

    const tmux_path = (try findTmux(alloc)) orelse {
        log.warn("tmux binary not found, ignoring tmux command", .{});
        return false;
    };

    const dir_path = try socketDir(alloc);
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        // No socket directory simply means no tmux server has ever
        // run for this user.
        error.FileNotFound => return false,
        else => {
            log.warn("failed to open tmux socket dir path={s} err={}", .{ dir_path, err });
            return false;
        },
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .unix_domain_socket) continue;
        const sock = try std.fs.path.join(alloc, &.{ dir_path, entry.name });
        const session = (try attachedSession(alloc, tmux_path, sock, tty_name)) orelse continue;
        return try runCommand(alloc, tmux_path, sock, args, session);
    }

    return false;
}

/// The directory containing this user's tmux server sockets. This
/// mirrors tmux's own logic: `$TMUX_TMPDIR` (or /tmp) is the parent of
/// a per-uid `tmux-<uid>` directory holding one socket per server.
fn socketDir(alloc: Allocator) ![]const u8 {
    const parent: []const u8 = parent: {
        if (std.posix.getenv("TMUX_TMPDIR")) |v| {
            if (v.len > 0) break :parent v;
        }
        break :parent "/tmp";
    };
    return socketDirPath(alloc, parent, std.c.getuid());
}

fn socketDirPath(alloc: Allocator, parent: []const u8, uid: u32) ![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}/tmux-{d}", .{ parent, uid });
}

/// Locate the tmux binary. The app may have been launched from the
/// desktop with a minimal PATH that misses package-manager prefixes,
/// so a PATH search alone is not sufficient.
fn findTmux(alloc: Allocator) !?[]const u8 {
    if (path.expand(alloc, "tmux") catch null) |v| return v;
    for ([_][]const u8{
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
    }) |candidate| {
        std.fs.accessAbsolute(candidate, .{}) catch continue;
        return candidate;
    }
    return null;
}

/// Returns the session id of the client attached to tty_name on the
/// server at the given socket path, if any. A dead socket (server
/// exited) fails to connect and yields null.
fn attachedSession(
    alloc: Allocator,
    tmux_path: []const u8,
    sock: []const u8,
    tty_name: []const u8,
) !?[]const u8 {
    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{
            tmux_path,
            "-S",
            sock,
            "list-clients",
            "-F",
            "#{client_tty}\t#{session_id}",
        },
        .max_output_bytes = 32 * 1024,
    }) catch |err| {
        log.debug("tmux list-clients failed to spawn sock={s} err={}", .{ sock, err });
        return null;
    };
    if (!(run.term == .Exited and run.term.Exited == 0)) return null;
    return findSessionForTty(run.stdout, tty_name);
}

/// Parse `list-clients -F "#{client_tty}\t#{session_id}"` output and
/// return the session id for the client attached to tty_name, if any.
fn findSessionForTty(output: []const u8, tty_name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trimRight(u8, line_raw, "\r");
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], tty_name)) return line[tab + 1 ..];
    }
    return null;
}

fn runCommand(
    alloc: Allocator,
    tmux_path: []const u8,
    sock: []const u8,
    args: []const []const u8,
    session: []const u8,
) !bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ tmux_path, "-S", sock });
    try argv.appendSlice(alloc, args);

    // Target the matched session unless the command carries its own
    // target. Without an explicit -t the server would pick the most
    // recently used session, which is not necessarily ours.
    if (!hasTargetFlag(args)) try argv.appendSlice(alloc, &.{ "-t", session });

    const run = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .max_output_bytes = 32 * 1024,
    }) catch |err| {
        log.warn("tmux command failed to spawn err={}", .{err});
        return false;
    };
    if (!(run.term == .Exited and run.term.Exited == 0)) {
        log.warn("tmux command failed stderr={s}", .{run.stderr});
        return false;
    }
    return true;
}

fn hasTargetFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-t")) return true;
    }
    return false;
}

/// Split the configured command into argv tokens. ArgIteratorGeneral
/// gives best-effort shell-like quoting; there is no variable
/// expansion or globbing. The returned slices share the iterator's
/// buffer, which the arena owns.
fn splitArgs(alloc: Allocator, command: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var it = try std.process.ArgIteratorGeneral(.{}).init(alloc, command);
    while (it.next()) |arg| try out.append(alloc, arg);
    return out.items;
}

test "tmux: findSessionForTty matches the right client" {
    const testing = std.testing;
    const output = "/dev/ttys001\t$0\n/dev/ttys004\t$3\n";
    try testing.expectEqualStrings(
        "$3",
        findSessionForTty(output, "/dev/ttys004").?,
    );
    try testing.expectEqualStrings(
        "$0",
        findSessionForTty(output, "/dev/ttys001").?,
    );
    try testing.expect(findSessionForTty(output, "/dev/ttys002") == null);
}

test "tmux: findSessionForTty tolerates malformed and CRLF lines" {
    const testing = std.testing;
    const output = "garbage-no-tab\n\r\n/dev/ttys004\t$3\r\n";
    try testing.expectEqualStrings(
        "$3",
        findSessionForTty(output, "/dev/ttys004").?,
    );
    try testing.expect(findSessionForTty("", "/dev/ttys004") == null);
}

test "tmux: socketDirPath" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings(
        "/tmp/tmux-501",
        try socketDirPath(arena.allocator(), "/tmp", 501),
    );
}

test "tmux: splitArgs handles quoting" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const args = try splitArgs(alloc, "next-window");
        try testing.expectEqual(@as(usize, 1), args.len);
        try testing.expectEqualStrings("next-window", args[0]);
    }
    {
        const args = try splitArgs(alloc, "display-message \"hello world\"");
        try testing.expectEqual(@as(usize, 2), args.len);
        try testing.expectEqualStrings("hello world", args[1]);
    }
    {
        const args = try splitArgs(alloc, "  ");
        try testing.expectEqual(@as(usize, 0), args.len);
    }
}

test "tmux: hasTargetFlag" {
    const testing = std.testing;
    try testing.expect(hasTargetFlag(&.{ "select-window", "-t", "main" }));
    try testing.expect(hasTargetFlag(&.{ "select-window", "-tmain" }));
    try testing.expect(!hasTargetFlag(&.{"next-window"}));
}
