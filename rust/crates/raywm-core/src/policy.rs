//! Desktop policy implementation. This is part of the existing registry, not
//! an additional owner layered over it.
use super::*;
use crate::{
    commands::{Command, CommandError as E, CommandResult, Effect, Event},
    layout::{self, LayoutEngine, LayoutError, LayoutInput, LayoutPlan, LayoutWindow},
};

impl Desktop {
    pub fn windows(&self) -> impl Iterator<Item = &WindowState> {
        self.windows.values()
    }
    pub fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.workspaces.values()
    }
    pub fn workspace(&self, id: WorkspaceId) -> Option<&Workspace> {
        self.workspaces.get(&id)
    }
    pub fn workspace_windows(
        &self,
        id: WorkspaceId,
    ) -> Result<impl Iterator<Item = WindowId> + '_, E> {
        self.workspace(id).ok_or(E::UnknownWorkspace)?;
        Ok(self
            .windows
            .values()
            .filter(move |w| w.workspace == id)
            .map(|w| w.id))
    }
    pub fn active_workspace(&self) -> WorkspaceId {
        self.active_workspace
    }
    pub fn output(&self, id: OutputId) -> Option<&OutputState> {
        self.outputs.get(&id)
    }
    pub fn output_for(&self, id: WindowId) -> Option<OutputId> {
        let w = self.get(id).filter(|w| w.mapped())?;
        self.workspace(w.workspace)?.output
    }
    /// Workspaces created at startup share the first output until explicitly bound.
    pub fn hybrid(layout: LayoutKind) -> Self {
        let mut desktop = Self {
            default_layout: layout,
            automatic_workspaces: true,
            ..Self::default()
        };
        desktop.workspaces = (1..=9)
            .map(|raw| {
                let id = WorkspaceId(raw);
                (
                    id,
                    Workspace {
                        id,
                        output: None,
                        layout,
                        home: None,
                        explicitly_detached: false,
                        last_focus: None,
                    },
                )
            })
            .collect();
        desktop.next_workspace = Some(10);
        desktop
    }

    pub fn workspace_number(&self, number: usize) -> Option<WorkspaceId> {
        self.workspaces.keys().nth(number.checked_sub(1)?).copied()
    }

    fn tiled_base(&self, w: &WindowState) -> bool {
        w.parent.is_none()
            && !w.floating
            && self
                .workspace(w.workspace)
                .is_some_and(|ws| ws.output.is_some() && ws.layout != LayoutKind::Floating)
    }

    pub fn can_move_resize(&self, id: WindowId) -> bool {
        self.get(id)
            .is_some_and(|w| w.presentation == Presentation::Normal && !self.tiled_base(w))
    }

    fn active_tile(&self, workspace: WorkspaceId) -> Option<WindowId> {
        self.order
            .iter()
            .rev()
            .filter_map(|id| self.get(*id))
            .find(|w| {
                w.workspace == workspace
                    && self.tiled_base(w)
                    && w.presentation == Presentation::Normal
            })
            .map(|w| w.id)
    }

    fn fullscreen_root(&self, workspace: WorkspaceId) -> Option<WindowId> {
        self.order
            .iter()
            .rev()
            .filter_map(|id| self.get(*id))
            .find(|w| {
                w.workspace == workspace
                    && w.presentation == Presentation::Fullscreen
                    && self.output_for(w.id).is_some()
            })
            .map(|w| self.root(w.id))
    }

    pub(super) fn selectable(&self, id: WindowId) -> bool {
        self.get(id).is_some_and(|w| {
            w.mapped()
                && w.focus_eligible
                && self.workspace_visible(w.workspace)
                && self
                    .fullscreen_root(w.workspace)
                    .is_none_or(|root| root == self.root(id))
        })
    }

    pub fn visible(&self, id: WindowId) -> bool {
        let Some(w) = self
            .get(id)
            .filter(|w| w.mapped() && self.workspace_visible(w.workspace))
        else {
            return false;
        };
        let root = self.root(id);
        if let Some(fullscreen) = self.fullscreen_root(w.workspace) {
            return root == fullscreen;
        }
        let Some(parent) = self.get(root) else {
            return false;
        };
        let monocle = self
            .workspace(w.workspace)
            .is_some_and(|ws| ws.layout == LayoutKind::Monocle);
        !monocle
            || parent.presentation != Presentation::Normal
            || !self.tiled_base(parent)
            || self.active_tile(w.workspace) == Some(root)
    }

    fn workspace_visible(&self, id: WorkspaceId) -> bool {
        self.workspace(id).is_some_and(|ws| match ws.output {
            Some(output) => self
                .outputs
                .get(&output)
                .is_some_and(|o| o.active == Some(id)),
            None => {
                !self.automatic_workspaces && self.outputs.is_empty() && self.active_workspace == id
            }
        })
    }
    pub fn focusable(&self, id: WindowId) -> bool {
        self.visible(id) && self.get(id).is_some_and(|w| w.focus_eligible)
    }

    pub fn stacking_layer(&self, id: WindowId) -> u8 {
        let root = self.root(id);
        self.get(root).map_or(0, |w| match w.presentation {
            Presentation::Fullscreen => 4,
            Presentation::Maximized => 1,
            Presentation::Normal if self.tiled_base(w) => {
                let selected = self.workspace(w.workspace).and_then(|ws| ws.last_focus);
                if selected.is_some_and(|id| self.root(id) == root) {
                    2
                } else {
                    0
                }
            }
            Presentation::Normal => 3,
        })
    }

    pub fn set_size_hints(&mut self, id: WindowId, hints: SizeHints) -> bool {
        self.windows
            .get_mut(&id)
            .is_some_and(|w| std::mem::replace(&mut w.hints, hints) != hints)
    }

    /// Record only the scene position, keeping the saved floating position intact.
    pub fn place_at(&mut self, id: WindowId, position: Position) {
        if let Some(w) = self.windows.get_mut(&id) {
            w.position = position;
        }
    }

    pub(super) fn remember_workspace_focus(&mut self, id: WindowId) {
        let Some(ws) = self.get(id).map(|w| w.workspace) else {
            return;
        };
        self.active_workspace = ws;
        if let Some(workspace) = self.workspaces.get_mut(&ws) {
            workspace.last_focus = Some(id);
        }
    }

    pub(super) fn forget_workspace_focus(&mut self, id: WindowId) {
        let Some(ws) = self.get(id).map(|w| w.workspace) else {
            return;
        };
        if let Some(workspace) = self.workspaces.get_mut(&ws) {
            if workspace.last_focus == Some(id) {
                workspace.last_focus = None;
            }
        }
    }

    fn repair_focus(&mut self) {
        if self.focused().is_some_and(|id| !self.focusable(id)) {
            self.focus(None);
        }
        if let Some(id) = self.focused() {
            // Reparenting can move the focused window to another visible workspace.
            self.remember_workspace_focus(id);
        } else {
            self.focus(self.topmost());
        }
    }
    pub fn configuration(&self) -> &Configuration {
        &self.config
    }

    pub fn update_output(&mut self, id: OutputId, geometry: Geometry) -> Result<(), E> {
        self.update_output_area(id, geometry, geometry)
    }

    /// Output coordinates come from the backend. Usable bounds exclude reservations.
    pub fn update_output_area(
        &mut self,
        id: OutputId,
        geometry: Geometry,
        usable: Geometry,
    ) -> Result<(), E> {
        layout::validate_box(geometry).map_err(|_| E::InvalidGeometry)?;
        layout::validate_box(usable).map_err(|_| E::InvalidGeometry)?;
        if !layout::contains(geometry, usable) {
            return Err(E::InvalidGeometry);
        }
        if let Some(output) = self.outputs.get_mut(&id) {
            output.geometry = geometry;
            output.usable = usable;
            return Ok(());
        }
        let first = self.outputs.is_empty();
        let selected = self.active_workspace;
        self.outputs.insert(
            id,
            OutputState {
                geometry,
                usable,
                active: None,
            },
        );
        for ws in self.workspaces.values_mut() {
            if ws.explicitly_detached {
                continue;
            }
            if ws.home == Some(id)
                || (ws.output.is_none()
                    && (first && self.automatic_workspaces
                        || ws.home.is_none() && ws.id == selected))
            {
                ws.output = Some(id);
                ws.home = ws.home.or(Some(id));
            }
        }
        if self
            .workspace(selected)
            .is_some_and(|ws| ws.output == Some(id))
        {
            if let Some(output) = self.outputs.get_mut(&id) {
                output.active = Some(selected);
            }
        }
        self.repair_output_actives();
        self.repair_focus();
        Ok(())
    }

    /// Migrate temporarily to the first surviving output, or retain detached workspaces.
    /// A returning output reclaims its workspaces using its stable backend identity.
    pub fn remove_output(&mut self, id: OutputId) -> Result<(), E> {
        let removed = self.outputs.remove(&id).ok_or(E::UnknownOutput)?;
        let fallback = self.outputs.keys().next().copied();
        let affected: Vec<_> = self
            .windows
            .values()
            .filter(|w| {
                self.workspace(w.workspace)
                    .is_some_and(|ws| ws.output == Some(id))
            })
            .map(|w| w.id)
            .collect();
        for window in affected {
            self.cancel_operation(window);
        }
        for ws in self.workspaces.values_mut() {
            if ws.output == Some(id) {
                ws.output = fallback;
            }
        }
        if let Some(output) = fallback.and_then(|id| self.outputs.get_mut(&id)) {
            output.active = output.active.or(removed.active);
        }
        self.repair_output_actives();
        self.repair_focus();
        Ok(())
    }

    fn idle(&self) -> Result<(), E> {
        if self.interaction.is_some() {
            Err(E::Busy)
        } else {
            Ok(())
        }
    }
    fn mapped_window(&self, id: WindowId) -> Result<&WindowState, E> {
        let w = self.get(id).ok_or(E::UnknownWindow)?;
        if !w.mapped() {
            return Err(E::NotMapped);
        }
        if !self.visible(id) {
            return Err(E::NotVisible);
        }
        Ok(w)
    }
    fn root(&self, mut id: WindowId) -> WindowId {
        while let Some(parent) = self.get(id).and_then(|w| w.parent) {
            id = parent;
        }
        id
    }
    pub fn set_parent(&mut self, id: WindowId, parent: Option<WindowId>) -> Result<(), E> {
        self.get(id).ok_or(E::UnknownWindow)?;
        if let Some(mut current) = parent {
            loop {
                if current == id {
                    return Err(E::InvalidParent);
                }
                let w = self.get(current).ok_or(E::UnknownWindow)?;
                match w.parent {
                    Some(next) => current = next,
                    None => break,
                }
            }
        }
        let parent = parent.filter(|p| self.get(*p).is_some_and(|w| w.mapped()));
        let workspace = parent.and_then(|p| self.get(p)).map(|w| w.workspace);
        let children: Vec<_> = self
            .windows
            .keys()
            .copied()
            .filter(|child| self.descends_from(*child, id))
            .collect();
        if let Some(w) = self.windows.get_mut(&id) {
            w.parent = parent;
        }
        if let Some(workspace) = workspace {
            for child in children {
                if self.get(child).is_some_and(|w| w.workspace != workspace) {
                    self.forget_workspace_focus(child);
                    self.cancel_operation(child);
                }
                if let Some(w) = self.windows.get_mut(&child) {
                    w.workspace = workspace;
                }
            }
        }
        if self.get(id).is_some_and(|w| w.mapped()) {
            self.raise(id);
        }
        self.repair_focus();
        Ok(())
    }
    fn descends_from(&self, mut id: WindowId, ancestor: WindowId) -> bool {
        loop {
            if id == ancestor {
                return true;
            }
            match self.get(id).and_then(|w| w.parent) {
                Some(parent) => id = parent,
                None => return false,
            }
        }
    }
    pub(super) fn raise_family(&mut self, id: WindowId) {
        if self.get(id).is_some_and(|w| w.parent.is_none())
            && !self.windows.values().any(|w| w.parent == Some(id))
        {
            self.order.retain(|other| *other != id);
            self.order.push(id);
            return;
        }
        let root = self.root(id);
        let mut family: Vec<_> = self
            .order
            .iter()
            .copied()
            .filter(|id| self.root(*id) == root)
            .collect();
        family.sort_by_key(|id| {
            let mut depth = 0;
            let mut current = *id;
            while let Some(parent) = self.get(current).and_then(|w| w.parent) {
                depth += 1;
                current = parent;
            }
            depth
        });
        self.order.retain(|id| !family.contains(id));
        self.order.extend(family);
    }

    /// Compute and validate desired geometry for the active workspace on this output.
    pub fn layout_plan(&self, id: WorkspaceId) -> Result<LayoutPlan, LayoutError> {
        if self.workspace(id).is_none() {
            return Err(LayoutError::InvalidPlan);
        }
        if !self.workspace_visible(id) {
            return Ok(LayoutPlan {
                placements: Vec::new(),
            });
        }
        self.workspace_plan(id)
    }

    pub fn workspace_plan(&self, id: WorkspaceId) -> Result<LayoutPlan, LayoutError> {
        let ws = self.workspace(id).ok_or(LayoutError::InvalidPlan)?;
        let output = ws.output.and_then(|id| self.output(id));
        let mut order: Vec<_> = self
            .order
            .iter()
            .filter_map(|id| self.get(*id))
            .filter(|w| w.workspace == ws.id)
            .collect();
        order.sort_unstable_by_key(|w| w.tile_rank);
        let windows: Vec<_> = order
            .into_iter()
            .filter_map(|w| {
                let geometry = w.floating_geometry.or_else(|| {
                    Some(Geometry {
                        position: w.position,
                        size: w.size?,
                    })
                })?;
                let mut geometry =
                    output.map_or(geometry, |o| self.floating_on_output(w, geometry, o.usable));
                geometry.position.x = geometry
                    .position
                    .x
                    .min(i32::MAX - geometry.size.width.get() as i32);
                geometry.position.y = geometry
                    .position
                    .y
                    .min(i32::MAX - geometry.size.height.get() as i32);
                Some(LayoutWindow {
                    id: w.id,
                    geometry,
                    floating: w.floating || w.parent.is_some(),
                    presentation: if output.is_some() {
                        w.presentation
                    } else {
                        Presentation::Normal
                    },
                    hints: w.hints,
                })
            })
            .collect();
        ws.layout.arrange(&LayoutInput {
            bounds: output.map(|o| o.geometry),
            usable: output.map(|o| o.usable),
            parameters: self.config.layout,
            active_tile: self.active_tile(id),
            windows: &windows,
        })
    }

    fn floating_on_output(
        &self,
        window: &WindowState,
        mut geometry: Geometry,
        area: Geometry,
    ) -> Geometry {
        // Keep partially visible dragged windows in place. Recover entirely off-output
        // windows after an output change, and keep active grabs anchored as before.
        if self.interaction_window() == Some(window.id) || window.resize.is_some() {
            return geometry;
        }
        fn recover(origin: i32, length: u32, start: i32, span: u32) -> i32 {
            if i64::from(origin) + i64::from(length) <= i64::from(start)
                || i64::from(origin) >= i64::from(start) + i64::from(span)
            {
                start
            } else {
                origin
            }
        }
        geometry.position.x = recover(
            geometry.position.x,
            geometry.size.width.get(),
            area.position.x,
            area.size.width.get(),
        );
        geometry.position.y = recover(
            geometry.position.y,
            geometry.size.height.get(),
            area.position.y,
            area.size.height.get(),
        );
        geometry
    }

    pub fn workspace_output(&self, id: WindowId) -> Option<OutputId> {
        self.workspace(self.get(id)?.workspace)?.output
    }

    pub fn protocol_presentation(
        &mut self,
        id: WindowId,
        fullscreen: bool,
        enabled: bool,
    ) -> Result<(), E> {
        let w = self.get(id).ok_or(E::UnknownWindow)?;
        if enabled && self.workspace_output(id).is_none() {
            return Err(E::UnknownOutput);
        }
        // A protocol request can arrive during a floating resize or before map.
        if w.resize.is_some() || self.interaction_window() == Some(id) {
            self.cancel_operation(id);
        }
        self.change_presentation(id, fullscreen, enabled);
        Ok(())
    }

    fn change_presentation(&mut self, id: WindowId, fullscreen: bool, enabled: bool) {
        let Some(w) = self.windows.get_mut(&id) else {
            return;
        };
        let was_fullscreen = w.presentation == Presentation::Fullscreen;
        if !fullscreen {
            w.maximized = enabled;
        }
        w.presentation = if (fullscreen && enabled) || (!fullscreen && was_fullscreen) {
            Presentation::Fullscreen
        } else if w.maximized {
            Presentation::Maximized
        } else {
            Presentation::Normal
        };
        let show = w.presentation == Presentation::Fullscreen && !was_fullscreen && w.mapped();
        if show {
            self.raise_family(id);
        }
        self.repair_focus();
    }

    fn select_workspace(&mut self, id: WorkspaceId) -> Result<(), E> {
        let output = self.workspace(id).ok_or(E::UnknownWorkspace)?.output;
        if !self.outputs.is_empty() && output.is_none() {
            return Err(E::UnknownOutput);
        }
        self.idle()?;
        self.active_workspace = id;
        if let Some(o) = output.and_then(|o| self.outputs.get_mut(&o)) {
            o.active = Some(id);
        }
        let target = self
            .workspace(id)
            .and_then(|ws| ws.last_focus)
            .filter(|id| self.selectable(*id))
            .or_else(|| {
                self.order.iter().rev().copied().find(|w| {
                    self.get(*w).is_some_and(|w| w.workspace == id) && self.selectable(*w)
                })
            });
        self.focus(target);
        Ok(())
    }

    fn cycle_workspace(&self, forward: bool) -> Result<WorkspaceId, E> {
        let current = self.active_workspace;
        let output = self.workspace(current).and_then(|ws| ws.output);
        let ids: Vec<_> = self
            .workspaces
            .values()
            .filter(|ws| ws.output == output)
            .map(|ws| ws.id)
            .collect();
        cycle(&ids, Some(current), forward)
    }

    fn cycle_focus(&mut self, forward: bool) -> Result<(), E> {
        let mut ids: Vec<_> = self
            .windows
            .values()
            .filter(|w| self.selectable(w.id))
            .map(|w| (w.workspace, w.tile_rank, w.id))
            .collect();
        ids.sort_unstable();
        // The keyboard cycle includes every visible output in workspace order.
        let ids: Vec<_> = ids.into_iter().map(|(_, _, id)| id).collect();
        let target = cycle(&ids, self.focused(), forward)?;
        if !self.focus(Some(target)) {
            return Err(E::Busy);
        }
        Ok(())
    }

    pub fn execute(&mut self, command: Command) -> Result<CommandResult, E> {
        let previous_focus = self.focused();
        let mut result = CommandResult::default();
        match command {
            Command::FocusWindow(id) => {
                if let Some(id) = id {
                    let w = self.get(id).ok_or(E::UnknownWindow)?;
                    if !w.mapped() {
                        return Err(E::NotMapped);
                    }
                    if !self.selectable(id) {
                        return Err(E::NotVisible);
                    }
                }
                if !self.focus(id) {
                    return Err(E::Busy);
                }
            }
            Command::CloseWindow(id) => {
                self.get(id).ok_or(E::UnknownWindow)?;
                result.effects.push(Effect::CloseWindow(id));
            }
            Command::MoveWindow { id, position } => {
                let w = self.mapped_window(id)?;
                if w.resize.is_some() {
                    return Err(E::Busy);
                }
                if !self.can_move_resize(id) {
                    return Err(E::InvalidMode);
                }
                self.idle()?;
                self.move_to(id, position);
                result.events.push(Event::WindowMoved(id));
            }
            Command::ResizeWindow { id, size } => {
                validate_size(size)?;
                let w = self.mapped_window(id)?;
                if w.resize.is_some() {
                    return Err(E::Busy);
                }
                if !self.can_move_resize(id) {
                    return Err(E::InvalidMode);
                }
                let initial = Geometry {
                    position: w.position,
                    size: w.size.ok_or(E::InvalidGeometry)?,
                };
                self.idle()?;
                if let Some(w) = self.windows.get_mut(&id) {
                    w.resize = Some(ResizeState {
                        initial,
                        edges: Edges(10),
                        desired: size,
                        active: false,
                        sent: None,
                    });
                }
                result.events.push(Event::ResizeRequested(id));
            }
            Command::CreateWorkspace => {
                let raw = self.next_workspace.ok_or(E::IdExhausted)?;
                self.next_workspace = raw.checked_add(1);
                let id = WorkspaceId(raw);
                let output = if self.automatic_workspaces {
                    self.workspace(self.active_workspace)
                        .and_then(|ws| ws.output)
                } else {
                    None
                };
                self.workspaces.insert(
                    id,
                    Workspace {
                        id,
                        output,
                        home: output,
                        explicitly_detached: false,
                        last_focus: None,
                        layout: self.default_layout,
                    },
                );
                result.events.push(Event::WorkspaceCreated(id));
            }
            Command::RemoveWorkspace { id, fallback } => {
                self.workspace(id).ok_or(E::UnknownWorkspace)?;
                self.workspace(fallback).ok_or(E::UnknownWorkspace)?;
                if self.workspaces.len() == 1 {
                    return Err(E::LastWorkspace);
                }
                if id == fallback {
                    return Err(E::InvalidFallback);
                }
                self.idle()?;
                for w in self.windows.values_mut().filter(|w| w.workspace == id) {
                    w.workspace = fallback;
                    result.events.push(Event::WindowTransferred {
                        id: w.id,
                        from: id,
                        to: fallback,
                    });
                }
                self.workspaces.remove(&id);
                if self.active_workspace == id {
                    self.active_workspace = fallback;
                }
                self.repair_output_actives();
                self.repair_focus();
                result.events.push(Event::WorkspaceRemoved(id));
            }
            Command::ActivateWorkspace(id) => {
                self.select_workspace(id)?;
                result.events.push(Event::WorkspaceActivated(id));
            }
            Command::NextWorkspace | Command::PreviousWorkspace => {
                let id = self.cycle_workspace(matches!(command, Command::NextWorkspace))?;
                self.select_workspace(id)?;
                result.events.push(Event::WorkspaceActivated(id));
            }
            Command::FocusNext | Command::FocusPrevious => {
                self.cycle_focus(matches!(command, Command::FocusNext))?;
            }
            Command::MoveWindowToWorkspace { id, workspace } => {
                self.get(id).ok_or(E::UnknownWindow)?;
                self.workspace(workspace).ok_or(E::UnknownWorkspace)?;
                self.idle()?;
                let root = self.root(id);
                let family: Vec<_> = self
                    .windows
                    .keys()
                    .copied()
                    .filter(|id| self.root(*id) == root)
                    .collect();
                for id in family {
                    if self.get(id).is_some_and(|w| w.workspace != workspace) {
                        self.forget_workspace_focus(id);
                        self.cancel_operation(id);
                    }
                    if let Some(w) = self.windows.get_mut(&id) {
                        let from = w.workspace;
                        w.workspace = workspace;
                        result.events.push(Event::WindowTransferred {
                            id,
                            from,
                            to: workspace,
                        });
                    }
                }
                self.repair_focus();
            }
            Command::BindWorkspace { id, output } => {
                self.workspace(id).ok_or(E::UnknownWorkspace)?;
                if output.is_some_and(|o| !self.outputs.contains_key(&o)) {
                    return Err(E::UnknownOutput);
                }
                self.idle()?;
                if let Some(ws) = self.workspaces.get_mut(&id) {
                    ws.output = output;
                    ws.home = output;
                    ws.explicitly_detached = output.is_none();
                }
                self.repair_output_actives();
                self.repair_focus();
                result.events.push(Event::WorkspaceBound(id));
            }
            Command::SetLayout { id, .. } | Command::CycleLayout(id) => {
                let ws = self.workspace(id).ok_or(E::UnknownWorkspace)?;
                let layout = match command {
                    Command::SetLayout { layout, .. } => layout,
                    _ => ws.layout.next(),
                };
                self.idle()?;
                if let Some(ws) = self.workspaces.get_mut(&id) {
                    ws.layout = layout;
                }
                let cancelled: Vec<_> = self
                    .windows
                    .values()
                    .filter(|w| {
                        w.workspace == id && w.resize.is_some() && !self.can_move_resize(w.id)
                    })
                    .map(|w| w.id)
                    .collect();
                for id in cancelled {
                    self.cancel_operation(id);
                }
                self.repair_focus();
                result.events.push(Event::LayoutChanged(id));
            }
            Command::ToggleFloating(id) => {
                let w = self.mapped_window(id)?;
                if w.parent.is_some() {
                    return Err(E::InvalidMode);
                }
                self.idle()?;
                if let Some(w) = self.windows.get_mut(&id) {
                    w.floating = !w.floating;
                }
                if !self.can_move_resize(id) {
                    self.cancel_operation(id);
                }
                result.events.push(Event::WindowModeChanged(id));
            }
            Command::SetPresentation { id, .. }
            | Command::ToggleFullscreen(id)
            | Command::ToggleMaximized(id) => {
                let w = self.mapped_window(id)?;
                if self.workspace_output(id).is_none() {
                    return Err(E::UnknownOutput);
                }
                self.idle()?;
                let (is_fullscreen, is_maximized) =
                    (w.presentation == Presentation::Fullscreen, w.maximized);
                self.cancel_operation(id);
                match command {
                    Command::SetPresentation {
                        presentation: Presentation::Normal,
                        ..
                    } => {
                        self.change_presentation(id, false, false);
                        self.change_presentation(id, true, false);
                    }
                    Command::SetPresentation {
                        presentation: Presentation::Maximized,
                        ..
                    } => {
                        self.change_presentation(id, false, true);
                        self.change_presentation(id, true, false);
                    }
                    Command::SetPresentation {
                        presentation: Presentation::Fullscreen,
                        ..
                    } => self.change_presentation(id, true, true),
                    Command::ToggleFullscreen(_) => {
                        self.change_presentation(id, true, !is_fullscreen)
                    }
                    _ => self.change_presentation(id, false, !is_maximized),
                }
                result.events.push(Event::WindowModeChanged(id));
            }
            Command::ReorderWindow { id, forward } => {
                let w = self.mapped_window(id)?;
                if !self.tiled_base(w) || w.presentation != Presentation::Normal {
                    return Err(E::InvalidMode);
                }
                self.idle()?;
                let mut tiles: Vec<_> = self
                    .windows
                    .values()
                    .filter(|other| {
                        other.workspace == w.workspace
                            && other.mapped()
                            && self.tiled_base(other)
                            && other.presentation == Presentation::Normal
                    })
                    .map(|w| (w.tile_rank, w.id))
                    .collect();
                tiles.sort_unstable();
                let ids: Vec<_> = tiles.into_iter().map(|(_, id)| id).collect();
                let target = cycle(&ids, Some(id), forward)?;
                if id == target {
                    return Err(E::NoCandidate);
                }
                let previous = w.tile_rank;
                let next = self.get(target).ok_or(E::UnknownWindow)?.tile_rank;
                if let Some(w) = self.windows.get_mut(&target) {
                    w.tile_rank = previous;
                }
                if let Some(w) = self.windows.get_mut(&id) {
                    w.tile_rank = next;
                }
                result.events.push(Event::WindowReordered(id));
            }
            Command::SetMasterRatio(ratio) => {
                self.idle()?;
                self.config.layout.master_ratio = ratio;
                result.events.push(Event::ConfigurationApplied);
            }
            Command::SetGaps(gaps) => {
                let mut config = self.config.clone();
                config.layout.gaps = gaps;
                config.validate().map_err(E::Configuration)?;
                self.idle()?;
                self.config = config;
                result.events.push(Event::ConfigurationApplied);
            }
            Command::ApplyConfiguration(config) => {
                config.validate().map_err(E::Configuration)?;
                self.idle()?;
                self.config = config;
                result.events.push(Event::ConfigurationApplied);
            }
        }
        if previous_focus != self.focused() {
            result.events.push(Event::FocusChanged(self.focused()));
        }
        Ok(result)
    }

    fn repair_output_actives(&mut self) {
        for (id, output) in &mut self.outputs {
            if !output.active.is_some_and(|active| {
                self.workspaces
                    .get(&active)
                    .is_some_and(|ws| ws.output == Some(*id))
            }) {
                output.active = self
                    .workspaces
                    .values()
                    .find(|ws| ws.output == Some(*id))
                    .map(|ws| ws.id);
            }
        }
    }
}

fn cycle<T: Copy + Eq>(ids: &[T], current: Option<T>, forward: bool) -> Result<T, E> {
    let last = ids.len().checked_sub(1).ok_or(E::NoCandidate)?;
    let index = match (ids.iter().position(|id| Some(*id) == current), forward) {
        (Some(index), true) if index < last => index + 1,
        (Some(index), false) if index > 0 => index - 1,
        (_, true) => 0,
        (_, false) => last,
    };
    Ok(ids[index])
}

fn validate_size(size: Size) -> Result<(), E> {
    if size.width.get() > i32::MAX as u32 || size.height.get() > i32::MAX as u32 {
        Err(E::InvalidGeometry)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn workspace_id_exhaustion_never_wraps() -> Result<(), E> {
        let mut desktop = Desktop {
            next_workspace: Some(u64::MAX),
            ..Desktop::default()
        };
        desktop.execute(Command::CreateWorkspace)?;
        assert_eq!(
            desktop.execute(Command::CreateWorkspace),
            Err(E::IdExhausted)
        );
        assert_eq!(desktop.workspaces.len(), 2);
        assert!(desktop.workspace(WorkspaceId(u64::MAX)).is_some());
        Ok(())
    }
}
