//! Gesturebinds maps trackpad gestures to keybind actions. It is the backing
//! type for the `gesture` config option. The syntax mirrors `keybind`:
//!
//!     gesture = <gesture> = [once:]<action>
//!
//! where <gesture> is a `Binding.Gesture` (e.g. `pinch-in`, `pinch-out`) and
//! <action> is any `Binding.Action`. The optional `once:` prefix fires the
//! action a single time per gesture instead of once per discrete step, which
//! is useful when binding a continuous gesture to a discrete action.
const Gesturebinds = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const inputpkg = @import("../input.zig");
const formatterpkg = @import("formatter.zig");

const Gesture = inputpkg.Binding.Gesture;
const Action = inputpkg.Binding.Action;

/// Per-binding flags. Mirrors the flag idiom of `Binding.Flags` but only
/// carries the flags that are meaningful for gestures.
pub const Flags = struct {
    /// Fire the action only once per gesture (from the "began" phase until the
    /// gesture ends) rather than once per discrete step. Set via the `once:`
    /// prefix on the action. Useful when binding a continuous gesture to a
    /// discrete action.
    once: bool = false,
};

pub const Value = struct {
    action: Action,
    flags: Flags = .{},
};

const Map = std.AutoArrayHashMapUnmanaged(Gesture, Value);

/// The allocator for this map is the arena for the parent config.
map: Map = .{},

/// Register the default gesture bindings.
pub fn init(self: *Gesturebinds, alloc: Allocator) !void {
    // We don't clear the old memory because it's in the arena and unlikely to
    // be free-able anyways (see Keybinds.init for the same reasoning).
    self.map = .{};

    // Pinch maps to font size by default, matching the conventional
    // macOS-terminal behavior: pinch out (zoom in) grows, pinch in shrinks.
    try self.map.put(alloc, .@"pinch-out", .{ .action = .{ .increase_font_size = 1 } });
    try self.map.put(alloc, .@"pinch-in", .{ .action = .{ .decrease_font_size = 1 } });
}

pub fn parseCLI(self: *Gesturebinds, alloc: Allocator, input_: ?[]const u8) !void {
    const value = input_ orelse return error.ValueRequired;

    // An empty value resets to the defaults, mirroring `keybind =`.
    if (value.len == 0) {
        try self.init(alloc);
        return;
    }

    // `clear` removes all bindings.
    if (std.mem.eql(u8, value, "clear")) {
        self.map = .{};
        return;
    }

    // Split on the first '=' into the gesture name and the action spec.
    const idx = std.mem.indexOfScalar(u8, value, '=') orelse
        return error.InvalidFormat;
    const name = std.mem.trim(u8, value[0..idx], &std.ascii.whitespace);
    var rhs = std.mem.trim(u8, value[idx + 1 ..], &std.ascii.whitespace);

    const gesture = std.meta.stringToEnum(Gesture, name) orelse
        return error.InvalidFormat;

    // An empty action removes the binding.
    if (rhs.len == 0) {
        _ = self.map.orderedRemove(gesture);
        return;
    }

    // Parse leading flag prefixes (currently only `once:`), mirroring the
    // keybind prefix-flag idiom in `Binding.Parser.parseFlags`. An unknown
    // prefix is left for the action parser, since action names themselves use
    // colons (e.g. `text:`, `csi:`).
    var flags: Flags = .{};
    while (std.mem.indexOfScalar(u8, rhs, ':')) |ci| {
        const prefix = rhs[0..ci];
        if (std.mem.eql(u8, prefix, "once")) {
            if (flags.once) return error.InvalidFormat;
            flags.once = true;
        } else break;
        rhs = rhs[ci + 1 ..];
    }

    // Parse and clone the action. `Action.parse` does not copy its byte-slice
    // parameters (text/csi/esc) and the input line is transient, so we must
    // clone into the arena to avoid a use-after-free.
    const action = try (try Action.parse(rhs)).clone(alloc);

    try self.map.put(alloc, gesture, .{ .action = action, .flags = flags });
}

/// Look up the binding for a gesture, if any.
pub fn get(self: Gesturebinds, gesture: Gesture) ?Value {
    return self.map.get(gesture);
}

/// The number of bindings in the map.
pub fn count(self: Gesturebinds) usize {
    return self.map.count();
}

/// Deep copy of the struct. Required by Config.
pub fn clone(self: *const Gesturebinds, alloc: Allocator) Allocator.Error!Gesturebinds {
    var map: Map = .{};
    try map.ensureTotalCapacity(alloc, self.map.count());
    var it = self.map.iterator();
    while (it.next()) |entry| {
        map.putAssumeCapacity(entry.key_ptr.*, .{
            .action = try entry.value_ptr.action.clone(alloc),
            .flags = entry.value_ptr.flags,
        });
    }
    return .{ .map = map };
}

/// Compare if two of our values are equal. Required by Config.
pub fn equal(self: Gesturebinds, other: Gesturebinds) bool {
    if (self.map.count() != other.map.count()) return false;
    var it = self.map.iterator();
    while (it.next()) |entry| {
        const other_value = other.map.get(entry.key_ptr.*) orelse return false;
        if (!std.meta.eql(entry.value_ptr.flags, other_value.flags)) return false;
        if (!entry.value_ptr.action.equal(other_value.action)) return false;
    }
    return true;
}

/// Used by the formatter. Required by Config.
pub fn formatEntry(self: Gesturebinds, formatter: formatterpkg.EntryFormatter) !void {
    // If no items, we want to render an empty field.
    if (self.map.count() == 0) {
        try formatter.formatEntry(void, {});
        return;
    }

    var buf: [1024]u8 = undefined;
    var it = self.map.iterator();
    while (it.next()) |entry| {
        var writer: std.Io.Writer = .fixed(&buf);
        writer.print("{s}=", .{@tagName(entry.key_ptr.*)}) catch return error.OutOfMemory;
        if (entry.value_ptr.flags.once)
            writer.writeAll("once:") catch return error.OutOfMemory;
        entry.value_ptr.action.format(&writer) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, writer.buffer[0..writer.end]);
    }
}

test "parseCLI: continuous action, no flags" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "pinch-out=increase_font_size:1");
    const v = g.get(.@"pinch-out").?;
    try testing.expect(v.action == .increase_font_size);
    try testing.expectEqual(@as(f32, 1), v.action.increase_font_size);
    try testing.expect(!v.flags.once);
}

test "parseCLI: discrete text action with once flag" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    // The config value contains a literal backslash escape; the text action
    // stores it verbatim and only interprets it when performed.
    try g.parseCLI(alloc, "pinch-in=once:text:\\x02s");
    const v = g.get(.@"pinch-in").?;
    try testing.expect(v.flags.once);
    try testing.expect(v.action == .text);
    try testing.expectEqualStrings("\\x02s", v.action.text);
}

test "parseCLI: invalid gesture name" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try testing.expectError(
        error.InvalidFormat,
        g.parseCLI(alloc, "pinch-sideways=increase_font_size:1"),
    );
}

test "parseCLI: empty action removes binding" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.init(alloc);
    try testing.expect(g.get(.@"pinch-in") != null);
    try g.parseCLI(alloc, "pinch-in=");
    try testing.expect(g.get(.@"pinch-in") == null);
}

test "parseCLI: empty value resets to defaults" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "pinch-in=");
    try g.parseCLI(alloc, "");
    try testing.expect(g.get(.@"pinch-in").?.action == .decrease_font_size);
    try testing.expect(g.get(.@"pinch-out").?.action == .increase_font_size);
}

test "init: defaults present" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.init(alloc);
    try testing.expectEqual(@as(usize, 2), g.count());
    try testing.expect(g.get(.@"pinch-in").?.action == .decrease_font_size);
    try testing.expect(g.get(.@"pinch-out").?.action == .increase_font_size);
}

test "formatEntry: once flag round-trips" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "pinch-in=once:reset_font_size");
    try g.formatEntry(formatterpkg.entryFormatter("gesture", &buf.writer));
    try testing.expectEqualStrings(
        "gesture = pinch-in=once:reset_font_size\n",
        buf.written(),
    );
}

test "formatEntry: empty renders empty field" {
    const testing = std.testing;
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var g: Gesturebinds = .{};
    try g.formatEntry(formatterpkg.entryFormatter("gesture", &buf.writer));
    try testing.expectEqualStrings("gesture = \n", buf.written());
}

test "parseCLI: smart-magnify discrete gesture" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "smart-magnify=text:\\x02s");
    const v = g.get(.@"smart-magnify").?;
    try testing.expect(v.action == .text);
    try testing.expectEqualStrings("\\x02s", v.action.text);
}
