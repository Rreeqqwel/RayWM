//! Workspaces: groups of windows. Each workspace belongs to an output,
//! which shows one of its workspaces at a time (its active workspace);
//! windows on the others are hidden. How many workspaces there are, their
//! names and keys is policy (config/plugins/workspaces.lua). The core keeps
//! them consistent through output hotplug and reloads, and never leaves
//! keyboard focus on a hidden window.
//!
//! A special workspace (`special = true`) is an overlay: it is never the
//! output's active workspace. At most one special workspace per output is
//! shown (`Output.special_ws`); its windows then float above the active
//! workspace without hiding it. Showing a normal workspace hides the
//! overlay. Policy lives in config/plugins/special.lua.
//!
//! Ownership: a workspace belongs to the plugin that created it (it is a
//! registration of that plugin). When the plugin goes away (an error, a
//! reload), the workspace becomes an orphan: windows and state are kept,
//! and a plugin may adopt it (ctx.workspace_adopt). After every (re)load of
//! the configuration, orphans nobody adopted are removed; their windows
//! then belong to no workspace and are visible. So no window is ever lost
//! because a workspace plugin failed or was removed from the config.
//!
//! When an output goes away, its workspaces move to a remaining output (as
//! inactive workspaces there, with their windows); with no output left
//! they wait, hidden, for the next one. `home` remembers the output a
//! workspace was created on, so a plugin can move it back.
const std = @import("std");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const srv = @import("server.zig");
const Server = srv.Server;
const Output = srv.Output;
const View = @import("view.zig").View;
const gpa = srv.gpa;
const log = std.log.scoped(.workspace);

pub const max_name = 64;

pub const Workspace = struct {
    server: *Server,
    /// From the shared id space of views and outputs; never reused.
    id: u32,
    name: [:0]u8,
    /// Name of the output it was created on.
    home: [:0]u8,
    /// The output it belongs to; null only while no output exists.
    output: ?*Output,
    /// Geometry retained while no output exists.
    last_box: ?wlr.Box = null,
    /// In server.workspaces, in creation order.
    link: wl.list.Link = undefined,
    /// No plugin owns it (see the file comment).
    orphan: bool = false,
    /// One of its windows wants attention (until that window is focused).
    urgent: bool = false,
    /// An overlay, never the output's active workspace (see the file comment).
    special: bool = false,

    pub fn create(server: *Server, output: *Output, name: []const u8, special: bool) !*Workspace {
        if (name.len == 0 or name.len > max_name) return error.BadName;
        const ws = try gpa.create(Workspace);
        errdefer gpa.destroy(ws);
        const owned = try gpa.dupeZ(u8, name);
        errdefer gpa.free(owned);
        const home = try gpa.dupeZ(u8, std.mem.span(output.wlr_output.name));
        ws.* = .{
            .server = server,
            .id = server.nextId(),
            .name = owned,
            .home = home,
            .output = output,
            .special = special,
        };
        server.workspaces.append(ws);
        // An output with workspaces always shows one of them. A special
        // workspace is an overlay and never becomes that one.
        if (!special and output.active_ws == null) output.active_ws = ws;
        server.emit(.workspace_add, ws.id);
        return ws;
    }

    /// Removes the workspace. Its windows belong to no workspace afterwards
    /// and are visible (plugins move them first if they want otherwise).
    pub fn destroy(ws: *Workspace) void {
        const server = ws.server;
        const id = ws.id;
        ws.link.remove();
        if (ws.output) |o| {
            if (o.active_ws == ws) o.active_ws = firstOn(server, o);
            if (o.special_ws == ws) o.special_ws = null;
        }
        // Ids of the mapped windows it had, for their view_workspace events
        // (sent once the native state is consistent again).
        var moved: std.ArrayList(u32) = .empty;
        defer moved.deinit(gpa);
        var it = server.view_ids.valueIterator();
        while (it.next()) |vp| {
            const v = vp.*;
            if (v.workspace != ws) continue;
            v.workspace = null;
            v.updateVisibility();
            // A removed overlay releases its windows to the normal layers.
            v.restack();
            if (v.announced) moved.append(gpa, v.id) catch {};
        }
        gpa.free(ws.name);
        gpa.free(ws.home);
        gpa.destroy(ws);
        // Every window of this output may have changed visibility.
        server.afterVisibilityChange();
        server.emit(.workspace_remove, id);
        for (moved.items) |vid| server.emitArgs(.view_workspace, vid, &.{ .{ .int = 0 }, .{ .int = id } });
    }

    /// Shown: the active workspace of its output, or a special workspace
    /// currently overlaying it.
    pub fn isActive(ws: *Workspace) bool {
        const o = ws.output orelse return false;
        return if (ws.special) o.special_ws == ws else o.active_ws == ws;
    }

    /// Shows this workspace on its output, hiding the one shown before, and
    /// gives the keyboard to its most recently focused window (or to none).
    /// A special workspace is only shown as an overlay (`setShown`).
    pub fn activate(ws: *Workspace) bool {
        if (ws.special) {
            const server = ws.server;
            const id = ws.id;
            _ = ws.setShown(true);
            const after = byId(server, id) orelse return false;
            return after.isActive();
        }
        const server = ws.server;
        const id = ws.id;
        const output = ws.output orelse return false;
        // A normal workspace replaces the visible special overlay.
        const hidden = hideSpecial(server, output);
        if (output.active_ws == ws) {
            if (hidden != null) {
                server.focusWorkspace(ws);
                server.afterVisibilityChange();
            }
            return true;
        }
        server.emitArgs(.workspace_will_activate, id, &.{.{ .int = if (output.active_ws) |old| old.id else 0 }});
        // Event handlers can remove or move workspaces synchronously.
        const target = byId(server, id) orelse return false;
        const o = target.output orelse return false;
        const old = o.active_ws;
        if (old == target) return true;
        const old_id = if (old) |w| w.id else 0;
        o.active_ws = target;
        var it = server.view_ids.valueIterator();
        while (it.next()) |vp| {
            const v = vp.*;
            if (v.workspace == target or (old != null and v.workspace == old)) v.updateVisibility();
        }
        server.focusWorkspace(target);
        server.afterVisibilityChange();
        server.emitArgs(.workspace_activate, id, &.{.{ .int = old_id }});
        return true;
    }

    /// Shows (`on`) or hides this special workspace as an overlay on its
    /// output, keeping that output's active workspace visible. Only one
    /// special workspace is shown per output. Returns whether it is shown
    /// afterwards; false when `ws` is not special or has no output.
    pub fn setShown(ws: *Workspace, on: bool) bool {
        if (!ws.special) return false;
        const server = ws.server;
        const id = ws.id;
        const output = ws.output orelse return false;
        if (on) {
            if (output.special_ws == ws) return true;
            if (output.special_ws != null) _ = hideSpecial(server, output);
            // Event handlers can remove the workspace synchronously.
            const target = byId(server, id) orelse return false;
            const o = target.output orelse return false;
            o.special_ws = target;
            var it = server.view_ids.valueIterator();
            while (it.next()) |vp| {
                const v = vp.*;
                if (v.workspace == target) {
                    v.updateVisibility();
                    v.restack();
                }
            }
            server.focusWorkspace(target);
            server.afterVisibilityChange();
            server.emitArgs(.workspace_special, id, &.{.{ .boolean = true }});
            server.emit(.workspace_change, id);
            return true;
        }
        if (output.special_ws != ws) return false;
        _ = hideSpecial(server, output);
        if (output.active_ws) |active| server.focusWorkspace(active) else server.focus(null);
        server.afterVisibilityChange();
        return false;
    }

    /// Recomputes `urgent` from the windows on the workspace.
    pub fn updateUrgent(ws: *Workspace) void {
        var any = false;
        var it = ws.server.view_ids.valueIterator();
        while (it.next()) |vp| if (vp.*.workspace == ws and vp.*.urgent) {
            any = true;
            break;
        };
        if (any == ws.urgent) return;
        ws.urgent = any;
        ws.server.emit(.workspace_change, ws.id);
    }

    pub fn rename(ws: *Workspace, name: []const u8) !void {
        if (name.len == 0 or name.len > max_name) return error.BadName;
        const owned = try gpa.dupeZ(u8, name);
        gpa.free(ws.name);
        ws.name = owned;
        ws.server.emit(.workspace_change, ws.id);
    }

    /// Moves the workspace (with its windows) to `out`. It is shown there
    /// only if `out` showed no workspace; its old output shows another one.
    pub fn setOutput(ws: *Workspace, out: ?*Output) void {
        const old = ws.output;
        if (old == out) return;
        const server = ws.server;
        const source = if (old) |o| o.box() orelse o.last_box else ws.last_box;
        if (out == null) ws.last_box = source;
        ws.output = out;
        if (old) |o| {
            if (o.active_ws == ws) o.active_ws = firstOn(server, o);
            // The overlay is not carried to another output by itself.
            if (o.special_ws == ws) o.special_ws = null;
        }
        if (out) |o| if (!ws.special and o.active_ws == null) {
            o.active_ws = ws;
        };
        // Windows go along, at the same place relative to the output.
        if (out) |target| {
            var it = server.view_ids.valueIterator();
            while (it.next()) |vp| if (vp.*.workspace == ws) vp.*.moveToOutput(source, target);
            ws.last_box = null;
        }
        var vit = server.view_ids.valueIterator();
        while (vit.next()) |vp| vp.*.updateVisibility();
        server.afterVisibilityChange();
        server.emit(.workspace_change, ws.id);
    }
};

/// Hides the special overlay shown on `o`, if any, and updates its windows.
/// Returns it, so the caller can decide where the keyboard goes afterwards.
fn hideSpecial(server: *Server, o: *Output) ?*Workspace {
    const ws = o.special_ws orelse return null;
    const id = ws.id;
    o.special_ws = null;
    var it = server.view_ids.valueIterator();
    while (it.next()) |vp| {
        const v = vp.*;
        if (v.workspace == ws) {
            v.updateVisibility();
            v.restack();
        }
    }
    server.emitArgs(.workspace_special, id, &.{.{ .boolean = false }});
    server.emit(.workspace_change, id);
    return ws;
}

/// The first non-special workspace of `o` in creation order, if any.
fn firstOn(server: *Server, o: *Output) ?*Workspace {
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |w| if (w.output == o and !w.special) return w;
    return null;
}

pub fn byId(server: *Server, id: u32) ?*Workspace {
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |w| if (w.id == id) return w;
    return null;
}

/// After an output left the layout: its workspaces move to the first
/// remaining output; with none left they wait for one. Also gives
/// workspaces waiting without an output to a new output.
pub fn rescue(server: *Server) void {
    var target: ?*Output = null;
    var outs = server.outputs.iterator(.forward);
    while (outs.next()) |o| if (o.inLayout()) {
        target = o;
        break;
    };
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |ws| {
        const o = ws.output;
        if (o != null and o.?.inLayout()) continue;
        if (o == null and target == null) continue;
        log.info("workspace {s} moves to output {s}", .{ ws.name, if (target) |t| std.mem.span(t.wlr_output.name) else "(none)" });
        ws.setOutput(target);
    }
}

/// Forgets a destroyed output (it may still be referenced while wlroots
/// tears it down).
pub fn outputGone(server: *Server, output: *Output) void {
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |ws| if (ws.output == output) ws.setOutput(null);
    output.active_ws = null;
}

/// Removes orphans nobody adopted (see the file comment).
pub fn settle(server: *Server) void {
    var it = server.workspaces.safeIterator(.forward);
    while (it.next()) |ws| if (ws.orphan) {
        log.info("workspace {s} has no plugin any more; its windows stay visible", .{ws.name});
        ws.destroy();
    };
}

/// At shutdown: frees every workspace without emitting events.
pub fn deinitAll(server: *Server) void {
    var it = server.workspaces.safeIterator(.forward);
    while (it.next()) |ws| {
        ws.link.remove();
        gpa.free(ws.name);
        gpa.free(ws.home);
        gpa.destroy(ws);
    }
}
