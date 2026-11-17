//! Membership lives exclusively on WindowState; workspace window lists are queries.
use crate::{
    layout::LayoutKind,
    windows::{Geometry, OutputId},
};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WorkspaceId(pub(crate) u64);
impl WorkspaceId {
    pub fn get(self) -> u64 {
        self.0
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub output: Option<OutputId>,
    pub layout: LayoutKind,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct OutputState {
    pub geometry: Geometry,
    pub active: Option<WorkspaceId>,
}
