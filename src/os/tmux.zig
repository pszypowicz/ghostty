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
/// The tmux command is tokenized with sh-like quoting but without any
/// expansion. Every `%session%` in the command is replaced with the
/// matched session id and every `%client%` with the tty name, while
/// tmux's own `%%` template notation passes through untouched. If a
/// placeholder was replaced or the command already carries a `-t`
/// target it runs as written; otherwise the session id is appended as
/// `-t <session>` so the command acts on the session visible in this
/// terminal.
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
        return try runCommand(alloc, tmux_path, sock, args, session, tty_name);
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
    client: []const u8,
) !bool {
    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    try argv.appendSlice(alloc, &.{ tmux_path, "-S", sock });
    try argv.appendSlice(alloc, try buildCommandArgs(alloc, args, session, client));

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

/// Build the command portion of the argv: the configured tokens with
/// every `%session%` replaced by the session id and every `%client%`
/// by the client tty, plus a trailing `-t <session>` when the command
/// does not target one itself. Without a target the server would act
/// on its most recently used session, which is not necessarily ours.
///
/// Appending is not always enough. tmux rejects flags that follow
/// positional arguments, commands nested inside `if-shell` or
/// `command-prompt` do not inherit the outer `-t`, and commit
/// templates such as choose-tree's run against the client that sent
/// the key, which for a socket-issued command is not the attached
/// terminal. The placeholders put the session and client wherever the
/// command needs them, and using one (like an explicit `-t`) disables
/// the automatic append. tmux's own `%%` template notation is left
/// untouched so templates can pass through unchanged.
fn buildCommandArgs(
    alloc: Allocator,
    args: []const []const u8,
    session: []const u8,
    client: []const u8,
) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var substituted = false;
    for (args) |arg| {
        var replaced = arg;
        if (std.mem.indexOf(u8, replaced, "%session%") != null) {
            substituted = true;
            replaced = try std.mem.replaceOwned(u8, alloc, replaced, "%session%", session);
        }
        if (std.mem.indexOf(u8, replaced, "%client%") != null) {
            substituted = true;
            replaced = try std.mem.replaceOwned(u8, alloc, replaced, "%client%", client);
        }
        try out.append(alloc, replaced);
    }
    if (!substituted and !hasTargetFlag(args)) {
        try out.appendSlice(alloc, &.{ "-t", session });
    }
    return out.items;
}

fn hasTargetFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-t")) return true;
    }
    return false;
}

/// Split the configured command into argv tokens with sh-like rules:
/// unquoted whitespace separates tokens, single quotes preserve their
/// span verbatim, double quotes allow `\"` and `\\` escapes, a
/// backslash outside quotes escapes the next character, and adjacent
/// quoted and unquoted spans join into one token. There is no
/// variable expansion or globbing. tmux parses command strings the
/// same way, so nested commands (if-shell branches, choose-tree
/// templates) quote identically here and in tmux.conf. An unclosed
/// quote runs to the end of the command.
fn splitArgs(alloc: Allocator, command: []const u8) ![]const []const u8 {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var token: std.ArrayListUnmanaged(u8) = .empty;
    var has_token = false;
    var i: usize = 0;
    while (i < command.len) : (i += 1) {
        const c = command[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => {
                if (has_token) {
                    try out.append(alloc, token.items);
                    token = .empty;
                    has_token = false;
                }
            },
            '\'' => {
                has_token = true;
                i += 1;
                const start = i;
                while (i < command.len and command[i] != '\'') i += 1;
                try token.appendSlice(alloc, command[start..i]);
            },
            '"' => {
                has_token = true;
                i += 1;
                while (i < command.len and command[i] != '"') : (i += 1) {
                    var ch = command[i];
                    if (ch == '\\' and i + 1 < command.len) {
                        const next = command[i + 1];
                        if (next == '"' or next == '\\') {
                            ch = next;
                            i += 1;
                        }
                    }
                    try token.append(alloc, ch);
                }
            },
            '\\' => {
                has_token = true;
                if (i + 1 < command.len) {
                    i += 1;
                    try token.append(alloc, command[i]);
                } else {
                    try token.append(alloc, c);
                }
            },
            else => {
                has_token = true;
                try token.append(alloc, c);
            },
        }
    }
    if (has_token) try out.append(alloc, token.items);
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
    {
        const args = try splitArgs(
            alloc,
            "if -F '#{==:#{pane_mode},tree-mode}' 'send-keys Down' next-window",
        );
        try testing.expectEqual(@as(usize, 5), args.len);
        try testing.expectEqualStrings("#{==:#{pane_mode},tree-mode}", args[2]);
        try testing.expectEqualStrings("send-keys Down", args[3]);
        try testing.expectEqualStrings("next-window", args[4]);
    }
    {
        // Escaped quotes inside a double-quoted span.
        const args = try splitArgs(alloc, "display-message \"a \\\"quoted\\\" word\"");
        try testing.expectEqual(@as(usize, 2), args.len);
        try testing.expectEqualStrings("a \"quoted\" word", args[1]);
    }
    {
        // Adjacent quoted and unquoted spans join into one token.
        const args = try splitArgs(alloc, "se'nd-k'eys C-\\\\");
        try testing.expectEqual(@as(usize, 2), args.len);
        try testing.expectEqualStrings("send-keys", args[0]);
        try testing.expectEqualStrings("C-\\", args[1]);
    }
}

test "tmux: splitArgs keeps a choose-tree template token intact" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A single-quoted if-shell branch carries a double-quoted commit
    // template; the template's `\"%%\"` must reach tmux verbatim.
    const args = try splitArgs(
        alloc,
        \\if -t %session% -F '#{==:#{pane_mode},tree-mode}' 'send-keys -t %session% Enter' 'choose-tree -Zs -t %session% "switch-client -c %client% -t \"%%\""'
        ,
    );
    try testing.expectEqual(@as(usize, 7), args.len);
    try testing.expectEqualStrings(
        \\choose-tree -Zs -t %session% "switch-client -c %client% -t \"%%\""
    ,
        args[6],
    );
}

test "tmux: hasTargetFlag" {
    const testing = std.testing;
    try testing.expect(hasTargetFlag(&.{ "select-window", "-t", "main" }));
    try testing.expect(hasTargetFlag(&.{ "select-window", "-tmain" }));
    try testing.expect(!hasTargetFlag(&.{"next-window"}));
}

fn expectArgs(expected: []const []const u8, actual: []const []const u8) !void {
    const testing = std.testing;
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

test "tmux: buildCommandArgs substitutes placeholders and skips the append" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try splitArgs(
        alloc,
        \\if -t %session% -F '#{==:#{pane_mode},tree-mode}' 'send-keys -t %session% Down' 'next-window -t %session%'
        ,
    );
    try expectArgs(&.{
        "if",
        "-t",
        "$3",
        "-F",
        "#{==:#{pane_mode},tree-mode}",
        "send-keys -t $3 Down",
        "next-window -t $3",
    }, try buildCommandArgs(alloc, args, "$3", "/dev/ttys004"));
}

test "tmux: buildCommandArgs substitutes %client% and keeps tmux %% intact" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const args = try splitArgs(
        alloc,
        \\choose-tree -Zs -t %session% 'switch-client -c %client% -t "%%"'
        ,
    );
    try expectArgs(&.{
        "choose-tree",
        "-Zs",
        "-t",
        "$3",
        \\switch-client -c /dev/ttys004 -t "%%"
        ,
    }, try buildCommandArgs(alloc, args, "$3", "/dev/ttys004"));
}

test "tmux: buildCommandArgs substitutes placeholders inside a larger token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectArgs(
        &.{ "switch-client", "-t$0" },
        try buildCommandArgs(alloc, &.{ "switch-client", "-t%session%" }, "$0", "/dev/ttys001"),
    );
    try expectArgs(
        &.{ "run-shell", "echo client=/dev/ttys001" },
        try buildCommandArgs(alloc, &.{ "run-shell", "echo client=%client%" }, "$0", "/dev/ttys001"),
    );
}

test "tmux: buildCommandArgs appends the target for a plain command" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectArgs(
        &.{ "next-window", "-t", "$1" },
        try buildCommandArgs(alloc, &.{"next-window"}, "$1", "/dev/ttys001"),
    );

    // Bare %% is tmux template notation, not a placeholder: it is left
    // untouched and does not count as a substitution.
    try expectArgs(
        &.{ "display-message", "50%% done", "-t", "$1" },
        try buildCommandArgs(alloc, &.{ "display-message", "50%% done" }, "$1", "/dev/ttys001"),
    );
}

test "tmux: buildCommandArgs keeps an explicit -t untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectArgs(
        &.{ "select-window", "-t", "main" },
        try buildCommandArgs(alloc, &.{ "select-window", "-t", "main" }, "$1", "/dev/ttys001"),
    );
}
