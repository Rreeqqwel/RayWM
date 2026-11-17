//! Synchronous policy requests and resulting facts/effects; no event bus.
use crate::{
    config::{ConfigError, Configuration},
    layout::{LayoutKind, Presentation},
    windows::{OutputId, Position, Size, WindowId},
    workspaces::WorkspaceId,
};
use std::{error::Error, fmt};

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Command {
    FocusWindow(Option<WindowId>),
    CloseWindow(WindowId),
    MoveWindow {
        id: WindowId,
        position: Position,
    },
    ResizeWindow {
        id: WindowId,
        size: Size,
    },
    CreateWorkspace,
    RemoveWorkspace {
        id: WorkspaceId,
        fallback: WorkspaceId,
    },
    ActivateWorkspace(WorkspaceId),
    MoveWindowToWorkspace {
        id: WindowId,
        workspace: WorkspaceId,
    },
    BindWorkspace {
        id: WorkspaceId,
        output: Option<OutputId>,
    },
    SetLayout {
        id: WorkspaceId,
        layout: LayoutKind,
    },
    ToggleFloating(WindowId),
    SetPresentation {
        id: WindowId,
        presentation: Presentation,
    },
    ApplyConfiguration(Configuration),
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum Event {
    FocusChanged(Option<WindowId>),
    WindowMoved(WindowId),
    ResizeRequested(WindowId),
    WorkspaceCreated(WorkspaceId),
    WorkspaceRemoved(WorkspaceId),
    WorkspaceActivated(WorkspaceId),
    WindowTransferred {
        id: WindowId,
        from: WorkspaceId,
        to: WorkspaceId,
    },
    WorkspaceBound(WorkspaceId),
    LayoutChanged(WorkspaceId),
    ConfigurationApplied,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Effect {
    CloseWindow(WindowId),
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CommandResult {
    pub events: Vec<Event>,
    pub effects: Vec<Effect>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CommandError {
    UnknownWindow,
    UnknownWorkspace,
    UnknownOutput,
    LastWorkspace,
    InvalidFallback,
    NotMapped,
    NotVisible,
    Busy,
    Unsupported,
    InvalidGeometry,
    InvalidParent,
    IdExhausted,
    Configuration(ConfigError),
}
impl fmt::Display for CommandError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "desktop command rejected: {self:?}")
    }
}
impl Error for CommandError {}
