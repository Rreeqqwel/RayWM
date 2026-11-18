//! Synchronous policy requests and resulting facts/effects; no event bus.
use crate::{
    config::{ConfigError, Configuration},
    layout::{Gaps, LayoutKind, MasterRatio, Presentation},
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
    NextWorkspace,
    PreviousWorkspace,
    FocusNext,
    FocusPrevious,
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
    CycleLayout(WorkspaceId),
    ToggleFloating(WindowId),
    ToggleFullscreen(WindowId),
    ToggleMaximized(WindowId),
    ReorderWindow {
        id: WindowId,
        forward: bool,
    },
    SetMasterRatio(MasterRatio),
    SetGaps(Gaps),
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
    WindowModeChanged(WindowId),
    WindowReordered(WindowId),
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
    InvalidMode,
    NoCandidate,
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
