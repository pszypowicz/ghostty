//! Gesturebinds maps trackpad gestures to keybind actions. It is the backing
//! type for the `gesture` config option. The syntax mirrors `keybind`:
//!
//!     gesture = [mods+]<gesture>[:<fingers>] = [flags:]<action>
//!
//! where <gesture> is a `Binding.Gesture` (e.g. `pinch-in`, `swipe-left`),
//! <fingers> is the finger count for swipe gestures (2-4, default 2), mods
//! use the same names and aliases as `keybind` triggers, and <action> is any
//! `Binding.Action`.
//!
//! Flags:
//!
//!   * `once:` fires the action a single time per gesture instead of once
//!     per discrete step, which is useful when binding a continuous gesture
//!     to a discrete action.
//!   * `force:` fires the binding even when gesture arbitration would defer
//!     to the running program (e.g. a two-finger swipe while the program
//!     enabled mouse reporting).
const Gesturebinds = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const inputpkg = @import("../input.zig");
const formatterpkg = @import("formatter.zig");

const Gesture = inputpkg.Binding.Gesture;
const Action = inputpkg.Binding.Action;
const Mods = inputpkg.Mods;

/// A gesture trigger: the gesture itself plus the qualifiers that must match
/// for the binding to fire.
pub const Trigger = struct {
    gesture: Gesture,

    /// Finger count for swipe gestures. Zero for gestures where the finger
    /// count is not part of the trigger (pinch, smart-magnify).
    fingers: u8 = 0,

    /// Modifier keys that must be held for the binding to match. Matching is
    /// exact against the bindable modifiers of the triggering event (sides
    /// and lock state are normalized away by the caller via `Mods.binding`).
    mods: Mods = .{},

    pub fn isSwipe(self: Trigger) bool {
        return switch (self.gesture) {
            .@"swipe-left", .@"swipe-right", .@"swipe-up", .@"swipe-down" => true,
            else => false,
        };
    }
};

/// Per-binding flags. Mirrors the flag idiom of `Binding.Flags` but only
/// carries the flags that are meaningful for gestures.
pub const Flags = struct {
    /// Fire the action only once per gesture (from the "began" phase until the
    /// gesture ends) rather than once per discrete step. Set via the `once:`
    /// prefix on the action. Useful when binding a continuous gesture to a
    /// discrete action.
    once: bool = false,

    /// Fire the binding even when gesture arbitration would normally defer
    /// to the running program (see Surface gesture arbitration). Set via the
    /// `force:` prefix on the action.
    force: bool = false,
};

pub const Value = struct {
    action: Action,
    flags: Flags = .{},
};

const Map = std.AutoArrayHashMapUnmanaged(Trigger, Value);

/// The allocator for this map is the arena for the parent config.
map: Map = .{},

/// Register the default gesture bindings.
pub fn init(self: *Gesturebinds, alloc: Allocator) !void {
    // We don't clear the old memory because it's in the arena and unlikely to
    // be free-able anyways (see Keybinds.init for the same reasoning).
    self.map = .{};

    // Pinch maps to font size by default, matching the conventional
    // macOS-terminal behavior: pinch out (zoom in) grows, pinch in shrinks.
    try self.map.put(
        alloc,
        .{ .gesture = .@"pinch-out" },
        .{ .action = .{ .increase_font_size = 1 } },
    );
    try self.map.put(
        alloc,
        .{ .gesture = .@"pinch-in" },
        .{ .action = .{ .decrease_font_size = 1 } },
    );

    // Two-finger horizontal swipes switch tabs by default, following the
    // content metaphor used by Safari: fingers moving left reveal the tab to
    // the right. This is safe out of the box because arbitration defers to
    // programs that enabled mouse reporting, and horizontal two-finger
    // motion has no consumer anywhere else.
    try self.map.put(
        alloc,
        .{ .gesture = .@"swipe-left", .fingers = 2 },
        .{ .action = .next_tab },
    );
    try self.map.put(
        alloc,
        .{ .gesture = .@"swipe-right", .fingers = 2 },
        .{ .action = .previous_tab },
    );
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

    // Split on the first '=' into the gesture trigger and the action spec.
    const idx = std.mem.indexOfScalar(u8, value, '=') orelse
        return error.InvalidFormat;
    const name = std.mem.trim(u8, value[0..idx], &std.ascii.whitespace);
    var rhs = std.mem.trim(u8, value[idx + 1 ..], &std.ascii.whitespace);

    const trigger = try parseTrigger(name);

    // An empty action removes the binding.
    if (rhs.len == 0) {
        _ = self.map.orderedRemove(trigger);
        return;
    }

    // Parse leading flag prefixes. Keybinds put flags before the trigger
    // (`performable:ctrl+c=copy`); gesture flags sit on the action side
    // deliberately, because they scope how the action fires (`once` per
    // gesture, `force` past arbitration), matching the action-prefix style
    // of `text:`/`csi:`. An unknown prefix is left for the action parser,
    // since action names themselves use colons.
    var flags: Flags = .{};
    while (std.mem.indexOfScalar(u8, rhs, ':')) |ci| {
        const prefix = rhs[0..ci];
        if (std.mem.eql(u8, prefix, "once")) {
            if (flags.once) return error.InvalidFormat;
            flags.once = true;
        } else if (std.mem.eql(u8, prefix, "force")) {
            if (flags.force) return error.InvalidFormat;
            flags.force = true;
        } else break;
        rhs = rhs[ci + 1 ..];
    }

    // Parse and clone the action. `Action.parse` does not copy its byte-slice
    // parameters (text/csi/esc) and the input line is transient, so we must
    // clone into the arena to avoid a use-after-free.
    const action = try (try Action.parse(rhs)).clone(alloc);

    try self.map.put(alloc, trigger, .{ .action = action, .flags = flags });
}

/// Parse the trigger side: `[mods+]<gesture>[:<fingers>]`. Mods use the same
/// names and aliases as keybind triggers. The finger-count suffix is only
/// valid on swipe gestures and defaults to 2 when omitted.
fn parseTrigger(name: []const u8) !Trigger {
    var mods: Mods = .{};
    var rem = name;
    while (std.mem.indexOfScalar(u8, rem, '+')) |plus| {
        const part = rem[0..plus];
        const m = inputpkg.Binding.parseModifierName(part) orelse
            return error.InvalidFormat;
        // Lock modifiers can never match: lookups use the binding mods,
        // which zero the locks - reject rather than accept a dead trigger.
        if (m.caps_lock or m.num_lock) return error.InvalidFormat;
        // Repeat not allowed
        const cur: Mods.Backing = @bitCast(mods);
        const add: Mods.Backing = @bitCast(m);
        if (cur & add != 0) return error.InvalidFormat;
        mods = @bitCast(cur | add);
        rem = rem[plus + 1 ..];
    }

    var fingers: u8 = 0;
    var gesture_name = rem;
    if (std.mem.indexOfScalar(u8, rem, ':')) |ci| {
        gesture_name = rem[0..ci];
        fingers = std.fmt.parseInt(u8, rem[ci + 1 ..], 10) catch
            return error.InvalidFormat;
        if (fingers == 0) return error.InvalidFormat;
    }

    const gesture = std.meta.stringToEnum(Gesture, gesture_name) orelse
        return error.InvalidFormat;

    var trigger: Trigger = .{ .gesture = gesture, .fingers = fingers, .mods = mods };
    if (trigger.isSwipe()) {
        if (fingers == 0) trigger.fingers = 2;
        if (trigger.fingers < 2 or trigger.fingers > 4) return error.InvalidFormat;
    } else {
        // A finger count is only meaningful on swipes.
        if (fingers != 0) return error.InvalidFormat;
    }

    return trigger;
}

/// Look up the binding for a gesture trigger, if any.
pub fn get(self: Gesturebinds, trigger: Trigger) ?Value {
    return self.map.get(trigger);
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
        writeTrigger(&writer, entry.key_ptr.*) catch return error.OutOfMemory;
        writer.writeAll("=") catch return error.OutOfMemory;
        if (entry.value_ptr.flags.once)
            writer.writeAll("once:") catch return error.OutOfMemory;
        if (entry.value_ptr.flags.force)
            writer.writeAll("force:") catch return error.OutOfMemory;
        entry.value_ptr.action.format(&writer) catch return error.OutOfMemory;
        try formatter.formatEntry([]const u8, writer.buffer[0..writer.end]);
    }
}

fn writeTrigger(writer: *std.Io.Writer, trigger: Trigger) !void {
    const modsInfo = @typeInfo(Mods).@"struct";
    inline for (modsInfo.fields) |field| {
        if (field.type == bool) {
            if (@field(trigger.mods, field.name))
                try writer.print("{s}+", .{field.name});
        }
    }
    try writer.print("{s}", .{@tagName(trigger.gesture)});
    if (trigger.fingers != 0) try writer.print(":{d}", .{trigger.fingers});
}

test "parseCLI: continuous action, no flags" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "pinch-out=increase_font_size:1");
    const v = g.get(.{ .gesture = .@"pinch-out" }).?;
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
    const v = g.get(.{ .gesture = .@"pinch-in" }).?;
    try testing.expect(v.flags.once);
    try testing.expect(v.action == .text);
    try testing.expectEqualStrings("\\x02s", v.action.text);
}

test "parseCLI: lock modifiers rejected" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try testing.expectError(
        error.InvalidFormat,
        g.parseCLI(alloc, "caps_lock+swipe-left:2=next_tab"),
    );
    try testing.expectError(
        error.InvalidFormat,
        g.parseCLI(alloc, "num_lock+pinch-in=increase_font_size:1"),
    );
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
    try testing.expect(g.get(.{ .gesture = .@"pinch-in" }) != null);
    try g.parseCLI(alloc, "pinch-in=");
    try testing.expect(g.get(.{ .gesture = .@"pinch-in" }) == null);
}

test "parseCLI: empty value resets to defaults" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "pinch-in=");
    try g.parseCLI(alloc, "");
    try testing.expect(g.get(.{ .gesture = .@"pinch-in" }).?.action == .decrease_font_size);
    try testing.expect(g.get(.{ .gesture = .@"pinch-out" }).?.action == .increase_font_size);
}

test "init: defaults present" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.init(alloc);
    try testing.expectEqual(@as(usize, 4), g.map.count());
    try testing.expect(g.get(.{ .gesture = .@"pinch-in" }).?.action == .decrease_font_size);
    try testing.expect(g.get(.{ .gesture = .@"pinch-out" }).?.action == .increase_font_size);
    try testing.expect(g.get(
        .{ .gesture = .@"swipe-left", .fingers = 2 },
    ).?.action == .next_tab);
    try testing.expect(g.get(
        .{ .gesture = .@"swipe-right", .fingers = 2 },
    ).?.action == .previous_tab);
}

test "parseCLI: swipe with explicit finger count" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "swipe-up:4=goto_split:up");
    const v = g.get(.{ .gesture = .@"swipe-up", .fingers = 4 }).?;
    try testing.expect(v.action == .goto_split);
}

test "parseCLI: swipe finger count defaults to 2" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "swipe-left=next_tab");
    try testing.expect(g.get(.{ .gesture = .@"swipe-left", .fingers = 2 }) != null);
}

test "parseCLI: swipe finger count out of range" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try testing.expectError(error.InvalidFormat, g.parseCLI(alloc, "swipe-left:1=next_tab"));
    try testing.expectError(error.InvalidFormat, g.parseCLI(alloc, "swipe-left:5=next_tab"));
}

test "parseCLI: finger count invalid on non-swipe" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try testing.expectError(error.InvalidFormat, g.parseCLI(alloc, "pinch-in:2=reset_font_size"));
}

test "parseCLI: swipe with modifiers" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    // `cmd` is an alias for super, mirroring keybind triggers.
    try g.parseCLI(alloc, "cmd+swipe-left:2=next_tab");
    const v = g.get(.{
        .gesture = .@"swipe-left",
        .fingers = 2,
        .mods = .{ .super = true },
    }).?;
    try testing.expect(v.action == .next_tab);

    // Repeated modifiers are invalid.
    try testing.expectError(
        error.InvalidFormat,
        g.parseCLI(alloc, "cmd+super+swipe-left:2=next_tab"),
    );

    // Unknown modifiers are invalid.
    try testing.expectError(
        error.InvalidFormat,
        g.parseCLI(alloc, "hyper+swipe-left:2=next_tab"),
    );
}

test "parseCLI: force flag" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "swipe-left:2=force:next_tab");
    const v = g.get(.{ .gesture = .@"swipe-left", .fingers = 2 }).?;
    try testing.expect(v.flags.force);
    try testing.expect(!v.flags.once);

    // Flags compose in either order.
    try g.parseCLI(alloc, "swipe-right:2=once:force:text:\\x02s");
    const v2 = g.get(.{ .gesture = .@"swipe-right", .fingers = 2 }).?;
    try testing.expect(v2.flags.force);
    try testing.expect(v2.flags.once);
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

test "formatEntry: swipe trigger with mods and fingers round-trips" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var g: Gesturebinds = .{};
    try g.parseCLI(alloc, "super+swipe-left:2=force:next_tab");
    try g.formatEntry(formatterpkg.entryFormatter("gesture", &buf.writer));
    try testing.expectEqualStrings(
        "gesture = super+swipe-left:2=force:next_tab\n",
        buf.written(),
    );

    // The formatted entry parses back to the same binding.
    var g2: Gesturebinds = .{};
    const formatted = buf.written();
    try g2.parseCLI(alloc, formatted["gesture = ".len .. formatted.len - 1]);
    try testing.expect(g.equal(g2));
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
    const v = g.get(.{ .gesture = .@"smart-magnify" }).?;
    try testing.expect(v.action == .text);
    try testing.expectEqualStrings("\\x02s", v.action.text);
}
