//! Pure desired-placement contract. Plans never mutate committed geometry.
use crate::windows::{Geometry, WindowId};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum LayoutKind {
    #[default]
    Floating,
    Tiling,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Presentation {
    #[default]
    Normal,
    Maximized,
    Fullscreen,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LayoutWindow {
    pub id: WindowId,
    pub geometry: Geometry,
    pub floating: bool,
    pub presentation: Presentation,
}

pub struct LayoutInput<'a> {
    pub bounds: Option<Geometry>,
    /// Visible mapped windows, in bottom-to-top order, without duplicate IDs.
    pub windows: &'a [LayoutWindow],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Placement {
    pub id: WindowId,
    pub geometry: Geometry,
    pub presentation: Presentation,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LayoutPlan {
    pub placements: Vec<Placement>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LayoutError {
    Unsupported,
    MissingOutput,
    InvalidGeometry,
    DuplicateWindow,
    InvalidPlan,
}

pub trait LayoutEngine {
    fn arrange(&self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError>;
}

/// Floating keeps committed geometry; stateful modes describe the output box.
/// Applying fullscreen/maximized protocol state is a later adapter capability.
pub struct Floating;
impl LayoutEngine for Floating {
    fn arrange(&self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError> {
        let plan = LayoutPlan {
            placements: input
                .windows
                .iter()
                .map(|window| {
                    let geometry = match window.presentation {
                        Presentation::Normal => window.geometry,
                        Presentation::Maximized | Presentation::Fullscreen => {
                            input.bounds.ok_or(LayoutError::MissingOutput)?
                        }
                    };
                    Ok(Placement {
                        id: window.id,
                        geometry,
                        presentation: window.presentation,
                    })
                })
                .collect::<Result<_, _>>()?,
        };
        plan.validate(input)?;
        Ok(plan)
    }
}

impl LayoutKind {
    pub fn arrange(self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError> {
        match self {
            Self::Floating => Floating.arrange(input),
            Self::Tiling => Err(LayoutError::Unsupported),
        }
    }
}

impl LayoutPlan {
    pub fn validate(&self, input: &LayoutInput<'_>) -> Result<(), LayoutError> {
        let mut ids = std::collections::BTreeSet::new();
        for window in input.windows {
            if !ids.insert(window.id) {
                return Err(LayoutError::DuplicateWindow);
            }
        }
        if self.placements.len() != ids.len() {
            return Err(LayoutError::InvalidPlan);
        }
        for placement in &self.placements {
            if !ids.remove(&placement.id) {
                return Err(LayoutError::InvalidPlan);
            }
            let size = placement.geometry.size;
            if size.width.get() > i32::MAX as u32 || size.height.get() > i32::MAX as u32 {
                return Err(LayoutError::InvalidGeometry);
            }
        }
        Ok(())
    }
}
