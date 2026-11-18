//! Pure desired placements. No protocol handles or committed state are changed.
use crate::windows::{Geometry, SizeHints, WindowId};

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum LayoutKind {
    #[default]
    Floating,
    MasterStack,
    Columns,
    Monocle,
}

impl LayoutKind {
    pub fn next(self) -> Self {
        match self {
            Self::MasterStack => Self::Columns,
            Self::Columns => Self::Monocle,
            Self::Monocle => Self::Floating,
            Self::Floating => Self::MasterStack,
        }
    }
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum Presentation {
    #[default]
    Normal,
    Maximized,
    Fullscreen,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Gaps {
    pub inner: u32,
    pub outer: u32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MasterRatio(u8);

impl MasterRatio {
    pub fn new(percent: u8) -> Option<Self> {
        (10..=90).contains(&percent).then_some(Self(percent))
    }

    pub fn percent(self) -> u8 {
        self.0
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LayoutParameters {
    pub gaps: Gaps,
    pub master_ratio: MasterRatio,
    pub master_count: std::num::NonZeroUsize,
}

impl Default for LayoutParameters {
    fn default() -> Self {
        Self {
            gaps: Gaps { inner: 8, outer: 8 },
            master_ratio: MasterRatio(55),
            master_count: std::num::NonZeroUsize::MIN,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LayoutWindow {
    pub id: WindowId,
    pub geometry: Geometry,
    pub floating: bool,
    pub presentation: Presentation,
    pub hints: SizeHints,
}

pub struct LayoutInput<'a> {
    pub bounds: Option<Geometry>,
    pub usable: Option<Geometry>,
    pub parameters: LayoutParameters,
    pub active_tile: Option<WindowId>,
    /// Mapped workspace windows in tiling order, without duplicate IDs.
    pub windows: &'a [LayoutWindow],
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Placement {
    pub id: WindowId,
    pub geometry: Geometry,
    pub presentation: Presentation,
    pub tiled: bool,
    pub visible: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LayoutPlan {
    pub placements: Vec<Placement>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum LayoutError {
    MissingOutput,
    InvalidGeometry,
    DuplicateWindow,
    InvalidPlan,
}

pub trait LayoutEngine {
    fn arrange(&self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError>;
}

pub struct Floating;
impl LayoutEngine for Floating {
    fn arrange(&self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError> {
        LayoutKind::Floating.arrange(input)
    }
}

impl LayoutEngine for LayoutKind {
    fn arrange(&self, input: &LayoutInput<'_>) -> Result<LayoutPlan, LayoutError> {
        let area = input.usable.or(input.bounds);
        let mut plan = LayoutPlan {
            placements: input
                .windows
                .iter()
                .map(|window| {
                    Ok(Placement {
                        id: window.id,
                        geometry: match window.presentation {
                            Presentation::Normal => window.geometry,
                            Presentation::Maximized => area.ok_or(LayoutError::MissingOutput)?,
                            Presentation::Fullscreen => {
                                input.bounds.ok_or(LayoutError::MissingOutput)?
                            }
                        },
                        presentation: window.presentation,
                        tiled: area.is_some()
                            && *self != Self::Floating
                            && !window.floating
                            && window.presentation == Presentation::Normal,
                        visible: true,
                    })
                })
                .collect::<Result<_, _>>()?,
        };
        if let Some(area) = area {
            validate_box(area)?;
            let area = inset(area, input.parameters.gaps.outer);
            let tiles: Vec<_> = plan
                .placements
                .iter_mut()
                .zip(input.windows)
                .filter(|(placement, _)| placement.tiled)
                .collect();
            match self {
                Self::Floating => {}
                Self::Columns => split_tiles(tiles, area, input.parameters.gaps.inner, true),
                Self::Monocle => {
                    let active = input
                        .active_tile
                        .filter(|id| tiles.iter().any(|(p, _)| p.id == *id))
                        .or_else(|| tiles.first().map(|(p, _)| p.id));
                    for (tile, window) in tiles {
                        tile.visible = Some(tile.id) == active;
                        tile.geometry = fit(area, window.hints);
                    }
                }
                Self::MasterStack => master_stack(tiles, area, input.parameters),
            }
        }
        plan.validate(input)?;
        Ok(plan)
    }
}

type Tile<'a> = (&'a mut Placement, &'a LayoutWindow);

fn master_stack(mut tiles: Vec<Tile<'_>>, area: Geometry, settings: LayoutParameters) {
    let master_count = settings.master_count.get();
    if tiles.len() <= master_count || area.size.width.get() == 1 {
        split_tiles(tiles, area, settings.gaps.inner, false);
        return;
    }
    let stack = tiles.split_off(master_count);
    let width = area.size.width.get();
    let min_width = |group: &[Tile<'_>]| {
        group
            .iter()
            .map(|(_, w)| minimum(w.hints, true))
            .max()
            .unwrap_or(1)
    };
    let master_min = min_width(&tiles);
    let stack_min = min_width(&stack);
    let required = master_min.saturating_add(stack_min);
    let gap = settings
        .gaps
        .inner
        .min(width.saturating_sub(if required <= width { required } else { 2 }));
    let available = width - gap;
    let desired = (u64::from(available) * u64::from(settings.master_ratio.percent()) / 100) as u32;
    let master_width = if master_min.saturating_add(stack_min) <= available {
        desired.clamp(master_min, available - stack_min)
    } else {
        desired.clamp(1, available - 1)
    };
    split_tiles(
        tiles,
        stripe(area, 0, master_width, true),
        settings.gaps.inner,
        false,
    );
    split_tiles(
        stack,
        stripe(area, master_width + gap, available - master_width, true),
        settings.gaps.inner,
        false,
    );
}

fn split_tiles(tiles: Vec<Tile<'_>>, area: Geometry, gap: u32, horizontal: bool) {
    let count = tiles.len() as u64;
    if count == 0 {
        return;
    }
    let length = if horizontal {
        area.size.width
    } else {
        area.size.height
    }
    .get();
    let mut minima: Vec<_> = tiles
        .iter()
        .map(|(_, w)| u64::from(minimum(w.hints, horizontal)))
        .collect();
    let required: u64 = minima.iter().sum();
    let length = u64::from(length);
    let reserve = if required <= length {
        required
    } else {
        // When there are more tiles than pixels, overlap only the surplus
        // at the final coordinate with a one-pixel box.
        minima.fill(1);
        count
    };
    let gap = u64::from(gap).min(length.saturating_sub(reserve) / count.saturating_sub(1).max(1));
    let usable = length - gap * (count - 1);
    // Find the largest equal allocation compatible with the feasible minima.
    let mut low = 0;
    let mut high = usable + 1;
    while low + 1 < high {
        let middle = (low + high) / 2;
        if minima.iter().map(|&min| min.max(middle)).sum::<u64>() <= usable {
            low = middle;
        } else {
            high = middle;
        }
    }
    let mut remainder = usable.saturating_sub(minima.iter().map(|&min| min.max(low)).sum());
    let mut offset = 0;
    for ((tile, window), min) in tiles.into_iter().zip(minima) {
        let extra = u64::from(remainder > 0 && min <= low);
        remainder -= extra;
        let span = min.max(low) + extra;
        tile.geometry = fit(
            stripe(area, offset.min(length - 1) as u32, span as u32, horizontal),
            window.hints,
        );
        offset += span + gap;
    }
}

fn minimum(hints: SizeHints, horizontal: bool) -> u32 {
    if horizontal { hints.min.0 } else { hints.min.1 }.clamp(1, i32::MAX as u32)
}

fn fit(mut area: Geometry, hints: SizeHints) -> Geometry {
    let limit = |size: std::num::NonZeroU32, min: u32, max: u32| {
        if max == 0 {
            size
        } else {
            size.min(std::num::NonZeroU32::new(max.max(min)).unwrap_or(std::num::NonZeroU32::MIN))
        }
    };
    area.size.width = limit(area.size.width, hints.min.0, hints.max.0);
    area.size.height = limit(area.size.height, hints.min.1, hints.max.1);
    area
}

fn inset(area: Geometry, gap: u32) -> Geometry {
    let x = gap.min((area.size.width.get() - 1) / 2);
    let y = gap.min((area.size.height.get() - 1) / 2);
    let area = stripe(area, x, area.size.width.get() - x * 2, true);
    stripe(area, y, area.size.height.get() - y * 2, false)
}

fn stripe(mut area: Geometry, offset: u32, span: u32, horizontal: bool) -> Geometry {
    let (position, length) = if horizontal {
        (&mut area.position.x, &mut area.size.width)
    } else {
        (&mut area.position.y, &mut area.size.height)
    };
    *position = position.saturating_add(offset as i32);
    *length = std::num::NonZeroU32::new(span).unwrap_or(std::num::NonZeroU32::MIN);
    area
}

pub(crate) fn validate_box(geometry: Geometry) -> Result<(), LayoutError> {
    fn valid(origin: i32, size: u32) -> bool {
        size <= i32::MAX as u32 && i64::from(origin) + i64::from(size) <= i64::from(i32::MAX)
    }
    if !valid(geometry.position.x, geometry.size.width.get())
        || !valid(geometry.position.y, geometry.size.height.get())
    {
        return Err(LayoutError::InvalidGeometry);
    }
    Ok(())
}

pub(crate) fn contains(outer: Geometry, inner: Geometry) -> bool {
    let end = |origin, size| i64::from(origin) + i64::from(size);
    inner.position.x >= outer.position.x
        && inner.position.y >= outer.position.y
        && end(inner.position.x, inner.size.width.get())
            <= end(outer.position.x, outer.size.width.get())
        && end(inner.position.y, inner.size.height.get())
            <= end(outer.position.y, outer.size.height.get())
}

impl LayoutPlan {
    pub fn validate(&self, input: &LayoutInput<'_>) -> Result<(), LayoutError> {
        use std::collections::BTreeMap;
        if let Some(bounds) = input.bounds {
            validate_box(bounds)?;
            if input.usable.is_some_and(|usable| !contains(bounds, usable)) {
                return Err(LayoutError::InvalidPlan);
            }
        }
        let mut ids = BTreeMap::new();
        for window in input.windows {
            if ids.insert(window.id, window).is_some() {
                return Err(LayoutError::DuplicateWindow);
            }
        }
        if self.placements.len() != ids.len() {
            return Err(LayoutError::InvalidPlan);
        }
        for placement in &self.placements {
            let window = ids.remove(&placement.id).ok_or(LayoutError::InvalidPlan)?;
            validate_box(placement.geometry)?;
            if placement.presentation != window.presentation
                || (placement.tiled
                    && (window.floating || window.presentation != Presentation::Normal))
                || (!placement.visible && !placement.tiled)
            {
                return Err(LayoutError::InvalidPlan);
            }
            let bound = match placement.presentation {
                Presentation::Fullscreen => input.bounds,
                Presentation::Maximized => input.usable.or(input.bounds),
                Presentation::Normal if placement.tiled => input.usable.or(input.bounds),
                Presentation::Normal => continue,
            };
            let Some(bound) = bound else {
                return Err(LayoutError::InvalidPlan);
            };
            if placement.presentation == Presentation::Normal {
                if !contains(bound, placement.geometry) {
                    return Err(LayoutError::InvalidPlan);
                }
            } else if bound != placement.geometry {
                return Err(LayoutError::InvalidPlan);
            }
        }
        Ok(())
    }
}
