//! Desktop policy implementation. This is part of the existing registry, not
//! an additional owner layered over it.
use super::*;
use crate::{
    commands::{Command, CommandError as E, CommandResult, Effect, Event},
    layout::{LayoutInput, LayoutPlan, LayoutWindow},
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
    pub fn visible(&self, id: WindowId) -> bool {
        self.get(id)
            .is_some_and(|w| w.mapped() && self.workspace_visible(w.workspace))
    }
    fn workspace_visible(&self, id: WorkspaceId) -> bool {
        self.workspace(id).is_some_and(|ws| match ws.output {
            Some(output) => self
                .outputs
                .get(&output)
                .is_some_and(|o| o.active == Some(id)),
            None => self.outputs.is_empty() && self.active_workspace == id,
        })
    }
    pub fn focusable(&self, id: WindowId) -> bool {
        self.visible(id) && self.get(id).is_some_and(|w| w.focus_eligible)
    }
    fn repair_focus(&mut self) {
        if self.focused().is_some_and(|id| !self.focusable(id)) {
            self.focus(None);
        }
        if self.focused().is_none() {
            self.focus(self.topmost());
        }
    }
    pub fn configuration(&self) -> &Configuration {
        &self.config
    }

    /// Backend observation. Existing output updates retain workspace bindings.
    /// A new output adopts the selected unbound workspace, otherwise stays empty.
    pub fn update_output(&mut self, id: OutputId, geometry: Geometry) -> Result<(), E> {
        validate_size(geometry.size)?;
        if let Some(output) = self.outputs.get_mut(&id) {
            output.geometry = geometry;
            return Ok(());
        }
        let adopt = self
            .workspace(self.active_workspace)
            .filter(|ws| ws.output.is_none())
            .map(|ws| ws.id);
        self.outputs.insert(
            id,
            OutputState {
                geometry,
                active: adopt,
            },
        );
        if let Some(ws) = adopt {
            if let Some(workspace) = self.workspaces.get_mut(&ws) {
                workspace.output = Some(id);
            }
        }
        self.repair_focus();
        Ok(())
    }
    /// Physical removal must succeed even during a grab. Cancel geometry
    /// operations; retain all windows/workspaces as detached logical state.
    pub fn remove_output(&mut self, id: OutputId) -> Result<(), E> {
        self.outputs.remove(&id).ok_or(E::UnknownOutput)?;
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
                ws.output = None;
            }
        }
        self.repair_focus();
        Ok(())
    }

    fn idle(&self) -> Result<(), E> {
        if self.interaction.is_some() || self.windows.values().any(|w| w.resize.is_some()) {
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

    /// Compute a plan from current committed data. The adapter applies positions
    /// only; protocol size changes still go through configure/ACK/commit.
    pub fn layout_plan(&self, id: WorkspaceId) -> Result<LayoutPlan, crate::layout::LayoutError> {
        use crate::layout::LayoutError;
        let ws = self.workspace(id).ok_or(LayoutError::InvalidPlan)?;
        let windows: Vec<_> = self
            .order
            .iter()
            .filter_map(|id| self.get(*id))
            .filter(|w| w.workspace == ws.id && self.visible(w.id))
            .filter_map(|w| {
                Some(LayoutWindow {
                    id: w.id,
                    geometry: Geometry {
                        position: w.position,
                        size: w.size?,
                    },
                    floating: w.floating,
                    presentation: w.presentation,
                })
            })
            .collect();
        ws.layout.arrange(&LayoutInput {
            bounds: ws.output.and_then(|o| self.output(o)).map(|o| o.geometry),
            windows: &windows,
        })
    }

    pub fn execute(&mut self, command: Command) -> Result<CommandResult, E> {
        let previous_focus = self.focused();
        let mut result = CommandResult::default();
        match command {
            Command::FocusWindow(id) => {
                if let Some(id) = id {
                    self.mapped_window(id)?;
                    if !self.focusable(id) {
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
                self.mapped_window(id)?;
                self.idle()?;
                self.move_to(id, position);
                result.events.push(Event::WindowMoved(id));
            }
            Command::ResizeWindow { id, size } => {
                validate_size(size)?;
                let w = self.mapped_window(id)?;
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
                self.workspaces.insert(
                    id,
                    Workspace {
                        id,
                        output: None,
                        layout: Default::default(),
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
                let output = self.workspace(id).ok_or(E::UnknownWorkspace)?.output;
                if !self.outputs.is_empty() && output.is_none() {
                    return Err(E::UnknownOutput);
                }
                self.idle()?;
                self.active_workspace = id;
                if let Some(o) = output.and_then(|o| self.outputs.get_mut(&o)) {
                    o.active = Some(id);
                }
                // Explicit activation focuses the selected workspace, even if
                // the previous window remains visible on another output.
                self.focus(None);
                let target = self.order.iter().rev().copied().find(|w| {
                    self.get(*w).is_some_and(|w| w.workspace == id) && self.focusable(*w)
                });
                self.focus(target);
                result.events.push(Event::WorkspaceActivated(id));
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
                }
                self.repair_output_actives();
                self.repair_focus();
                result.events.push(Event::WorkspaceBound(id));
            }
            Command::SetLayout { id, layout } => {
                self.workspace(id).ok_or(E::UnknownWorkspace)?;
                if layout != crate::layout::LayoutKind::Floating {
                    return Err(E::Unsupported);
                }
                self.idle()?;
                if let Some(ws) = self.workspaces.get_mut(&id) {
                    ws.layout = layout;
                }
                result.events.push(Event::LayoutChanged(id));
            }
            Command::ToggleFloating(id) => {
                self.get(id).ok_or(E::UnknownWindow)?;
                return Err(E::Unsupported);
            }
            Command::SetPresentation { id, .. } => {
                self.get(id).ok_or(E::UnknownWindow)?;
                return Err(E::Unsupported);
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
