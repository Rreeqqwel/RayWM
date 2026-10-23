//! Workspaces: groups of windows. Each workspace belongs to an output,
//! which shows one of its workspaces at a time (its active workspace);
//! windows on the others are hidden. How many workspaces there are, their
//! names and keys is policy (config/plugins/workspaces.lua). The core keeps
//! them consistent through output hotplug and reloads, and never leaves
//! keyboard focus on a hidden window.
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
    /// In server.workspaces, in creation order.
    link: wl.list.Link = undefined,
    /// No plugin owns it (see the file comment).
    orphan: bool = false,
    urgent: bool = false,

    pub fn create(server: *Server, output: *Output, name: []const u8) !*Workspace {
        if (name.len == 0 or name.len > max_name) return error.BadName;
        const ws = try gpa.create(Workspace);
        errdefer gpa.destroy(ws);
        const owned = try gpa.dupeZ(u8, name);
        errdefer gpa.free(owned);
        const home = try gpa.dupeZ(u8, std.mem.span(output.wlr_output.name));
        ws.* = .{ .server = server, .id = server.nextId(), .name = owned, .home = home, .output = output };
        server.workspaces.append(ws);
        // An output with workspaces always shows one of them.
        if (output.active_ws == null) output.active_ws = ws;
        server.emit(.workspace_add, ws.id);
        return ws;
    }

    /// Removes the workspace. Its windows belong to no workspace afterwards
    /// and are visible (plugins move them first if they want otherwise).
    pub fn destroy(ws: *Workspace) void {
        const server = ws.server;
        const id = ws.id;
        ws.link.remove();
        if (ws.output) |o| if (o.active_ws == ws) {
            o.active_ws = firstOn(server, o);
        };
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

    pub fn isActive(ws: *Workspace) bool {
        const o = ws.output orelse return false;
        return o.active_ws == ws;
    }

    /// Shows this workspace on its output, hiding the one shown before, and
    /// gives the keyboard to its most recently focused window (or to none).
    pub fn activate(ws: *Workspace) bool {
        const o = ws.output orelse return false;
        const old = o.active_ws;
        if (old == ws) return true;
        o.active_ws = ws;
        ws.urgent = false;
        const server = ws.server;
        var it = server.view_ids.valueIterator();
        while (it.next()) |vp| {
            const v = vp.*;
            if (v.workspace == ws or (old != null and v.workspace == old)) v.updateVisibility();
        }
        server.focusWorkspace(ws);
        server.afterVisibilityChange();
        server.emitArgs(.workspace_activate, ws.id, &.{.{ .int = if (old) |w| w.id else 0 }});
        return true;
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
        ws.output = out;
        if (old) |o| if (o.active_ws == ws) {
            o.active_ws = firstOn(server, o);
        };
        if (out) |o| if (o.active_ws == null) {
            o.active_ws = ws;
        };
        // Windows go along, at the same place relative to the output.
        if (old != null and out != null) {
            var it = server.view_ids.valueIterator();
            while (it.next()) |vp| if (vp.*.workspace == ws) vp.*.moveToOutput(old.?, out.?);
        }
        var vit = server.view_ids.valueIterator();
        while (vit.next()) |vp| vp.*.updateVisibility();
        server.afterVisibilityChange();
        server.emit(.workspace_change, ws.id);
    }
};

/// The first workspace of `o` in creation order, if any.
fn firstOn(server: *Server, o: *Output) ?*Workspace {
    var it = server.workspaces.iterator(.forward);
    while (it.next()) |w| if (w.output == o) return w;
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
