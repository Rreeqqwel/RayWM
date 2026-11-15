//! Small desktop model. IDs are never recycled, including after removal.

use std::{collections::BTreeMap, error::Error, fmt, num::NonZeroU32};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct WindowId(NonZeroU32);

impl WindowId {
    pub fn get(self) -> u32 {
        self.0.get()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputId {
    Nested,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub struct Position {
    pub x: i32,
    pub y: i32,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Size {
    pub width: NonZeroU32,
    pub height: NonZeroU32,
}

impl Size {
    pub fn new(width: u32, height: u32) -> Option<Self> {
        Some(Self {
            width: NonZeroU32::new(width)?,
            height: NonZeroU32::new(height)?,
        })
    }
}

#[derive(Debug)]
pub struct WindowState {
    pub id: WindowId,
    pub position: Position,
    pub size: Option<Size>,
    pub mapped: bool,
    pub focused: bool,
    pub output: Option<OutputId>,
    pub resize: Option<ResizeState>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Geometry {
    pub position: Position,
    pub size: Size,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Edges(u32);
impl Edges {
    pub fn new(bits: u32) -> Option<Self> {
        matches!(bits, 1 | 2 | 4 | 5 | 6 | 8 | 9 | 10).then_some(Self(bits))
    }
    pub fn left(self) -> bool {
        self.0 & 4 != 0
    }
    pub fn top(self) -> bool {
        self.0 & 1 != 0
    }
}

#[derive(Clone, Copy, Debug, Default)]
pub struct SizeHints {
    pub min: (u32, u32),
    pub max: (u32, u32),
}
impl SizeHints {
    pub fn constrain(self, width: i64, height: i64) -> Size {
        fn axis(value: i64, min: u32, max: u32) -> NonZeroU32 {
            let min = min.clamp(1, i32::MAX as u32);
            let max = if max == 0 {
                i32::MAX as u32
            } else {
                max.clamp(min, i32::MAX as u32)
            };
            // A clamped positive integer is a construction invariant.
            NonZeroU32::new(value.clamp(i64::from(min), i64::from(max)) as u32)
                .unwrap_or(NonZeroU32::MIN)
        }
        Size {
            width: axis(width, self.min.0, self.max.0),
            height: axis(height, self.min.1, self.max.1),
        }
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ResizeState {
    pub initial: Geometry,
    pub edges: Edges,
    pub desired: Size,
    pub active: bool,
    sent: Option<(Size, bool)>,
}

#[derive(Clone, Copy, Debug)]
enum Operation {
    Move,
    Resize,
}
#[derive(Clone, Copy, Debug)]
struct Interaction {
    id: WindowId,
    origin: Position,
    initial: Geometry,
    operation: Operation,
}

#[derive(Debug)]
pub struct IdExhausted;

impl fmt::Display for IdExhausted {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("window ID space exhausted")
    }
}

impl Error for IdExhausted {}

pub struct Desktop {
    next_id: Option<NonZeroU32>,
    windows: BTreeMap<WindowId, WindowState>,
    order: Vec<WindowId>,
    interaction: Option<Interaction>,
}

impl Default for Desktop {
    fn default() -> Self {
        Self {
            next_id: NonZeroU32::new(1),
            windows: BTreeMap::new(),
            order: Vec::new(),
            interaction: None,
        }
    }
}

impl Desktop {
    pub fn create(&mut self) -> Result<WindowId, IdExhausted> {
        let raw = self.next_id.ok_or(IdExhausted)?;
        self.next_id = raw.get().checked_add(1).and_then(NonZeroU32::new);
        let id = WindowId(raw);
        self.windows.insert(
            id,
            WindowState {
                id,
                position: Position::default(),
                size: None,
                mapped: false,
                focused: false,
                output: None,
                resize: None,
            },
        );
        Ok(id)
    }

    pub fn get(&self, id: WindowId) -> Option<&WindowState> {
        self.windows.get(&id)
    }

    pub fn remove(&mut self, id: WindowId) -> Option<WindowState> {
        self.cancel_operation(id);
        let focused = self.focused() == Some(id);
        self.order.retain(|other| *other != id);
        let removed = self.windows.remove(&id);
        if focused {
            self.focus(self.topmost());
        }
        removed
    }

    pub fn map(
        &mut self,
        id: WindowId,
        position: Position,
        size: Size,
        output: Option<OutputId>,
    ) -> bool {
        let Some(window) = self.windows.get_mut(&id) else {
            return false;
        };
        window.position = position;
        window.size = Some(size);
        window.output = output;
        if !window.mapped {
            self.order.push(id);
        }
        window.mapped = true;
        true
    }

    pub fn unmap(&mut self, id: WindowId) -> bool {
        self.cancel_operation(id);
        let Some(window) = self.windows.get_mut(&id) else {
            return false;
        };
        let focused = window.focused;
        window.mapped = false;
        window.focused = false;
        window.output = None;
        self.order.retain(|other| *other != id);
        if focused {
            self.focus(self.topmost());
        }
        true
    }

    /// Invalid/unmapped focus requests do not disturb the current focus.
    pub fn focus(&mut self, id: Option<WindowId>) -> bool {
        if self.interaction.is_some_and(|grab| Some(grab.id) != id) {
            return false;
        }
        if id.is_some_and(|id| !self.windows.get(&id).is_some_and(|window| window.mapped)) {
            return false;
        }
        for window in self.windows.values_mut() {
            window.focused = Some(window.id) == id;
        }
        if let Some(id) = id {
            self.raise(id);
        }
        true
    }

    pub fn focused(&self) -> Option<WindowId> {
        self.windows
            .values()
            .find(|window| window.focused)
            .map(|window| window.id)
    }

    pub fn stacking(&self) -> &[WindowId] {
        &self.order
    }

    pub fn topmost(&self) -> Option<WindowId> {
        self.order.last().copied()
    }

    pub fn raise(&mut self, id: WindowId) -> bool {
        if !self.windows.get(&id).is_some_and(|window| window.mapped) {
            return false;
        }
        self.order.retain(|other| *other != id);
        self.order.push(id);
        true
    }

    pub fn move_to(&mut self, id: WindowId, position: Position) -> bool {
        let Some(window) = self.windows.get_mut(&id).filter(|window| window.mapped) else {
            return false;
        };
        window.position = position;
        true
    }

    /// First live window keeps the Stage 2 single-window sizing. Subsequent
    /// windows use smaller cascade rectangles; no reference to a first ID is retained.
    pub fn placement(&self, id: WindowId, bounds: Size) -> Option<(Position, Size)> {
        let window = self.windows.get(&id)?;
        if let Some(size) = window.size {
            return Some((window.position, size));
        }
        let rank = self.windows.keys().take_while(|other| **other < id).count();
        let w = bounds.width.get().min(i32::MAX as u32);
        let h = bounds.height.get().min(i32::MAX as u32);
        let size = if rank == 0 {
            Size::new(w, h)?
        } else {
            Size::new(
                ((u64::from(w) * 3 / 5) as u32).max(1),
                ((u64::from(h) * 3 / 5) as u32).max(1),
            )?
        };
        let x_room = w.saturating_sub(size.width.get());
        let y_room = h.saturating_sub(size.height.get());
        let offset = (rank % 5) * 48;
        Some((
            Position {
                x: (offset as u32).min(x_room) as i32,
                y: (offset as u32).min(y_room) as i32,
            },
            size,
        ))
    }

    pub fn interaction_window(&self) -> Option<WindowId> {
        self.interaction.map(|grab| grab.id)
    }

    pub fn begin_move(&mut self, id: WindowId, origin: Position) -> bool {
        self.begin(id, origin, None)
    }
    pub fn begin_resize(&mut self, id: WindowId, origin: Position, edges: Edges) -> bool {
        self.begin(id, origin, Some(edges))
    }

    fn begin(&mut self, id: WindowId, origin: Position, edges: Option<Edges>) -> bool {
        if self.interaction.is_some() {
            return false;
        }
        let Some(window) = self
            .windows
            .get_mut(&id)
            .filter(|window| window.mapped && window.resize.is_none())
        else {
            return false;
        };
        let Some(size) = window.size else {
            return false;
        };
        let initial = Geometry {
            position: window.position,
            size,
        };
        if let Some(edges) = edges {
            window.resize = Some(ResizeState {
                initial,
                edges,
                desired: size,
                active: true,
                sent: None,
            });
        }
        self.interaction = Some(Interaction {
            id,
            origin,
            initial,
            operation: if edges.is_some() {
                Operation::Resize
            } else {
                Operation::Move
            },
        });
        true
    }

    pub fn drag_to(&mut self, point: Position, hints: SizeHints) -> bool {
        let Some(grab) = self.interaction else {
            return false;
        };
        let Some(window) = self.windows.get_mut(&grab.id) else {
            self.interaction = None;
            return false;
        };
        let dx = i64::from(point.x) - i64::from(grab.origin.x);
        let dy = i64::from(point.y) - i64::from(grab.origin.y);
        match grab.operation {
            Operation::Move => {
                window.position = Position {
                    x: clamp_coordinate(i64::from(grab.initial.position.x) + dx),
                    y: clamp_coordinate(i64::from(grab.initial.position.y) + dy),
                }
            }
            Operation::Resize => {
                if let Some(resize) = &mut window.resize {
                    let w = i64::from(grab.initial.size.width.get())
                        + if resize.edges.0 & 12 == 0 {
                            0
                        } else if resize.edges.left() {
                            -dx
                        } else {
                            dx
                        };
                    let h = i64::from(grab.initial.size.height.get())
                        + if resize.edges.0 & 3 == 0 {
                            0
                        } else if resize.edges.top() {
                            -dy
                        } else {
                            dy
                        };
                    resize.desired = hints.constrain(w, h);
                }
            }
        }
        true
    }

    pub fn finish_interaction(&mut self) {
        if let Some(grab) = self.interaction.take() {
            if let Some(resize) = self
                .windows
                .get_mut(&grab.id)
                .and_then(|window| window.resize.as_mut())
            {
                resize.active = false;
            }
        }
    }

    pub fn cancel_operation(&mut self, id: WindowId) {
        if self.interaction.is_some_and(|grab| grab.id == id) {
            self.interaction = None;
        }
        if let Some(window) = self.windows.get_mut(&id) {
            window.resize = None;
        }
    }

    pub fn resize_request(&self, id: WindowId) -> Option<(Size, bool)> {
        let resize = self.windows.get(&id)?.resize.as_ref()?;
        let request = (resize.desired, resize.active);
        (resize.sent != Some(request)).then_some(request)
    }

    pub fn mark_resize_sent(&mut self, id: WindowId, request: (Size, bool)) {
        if let Some(resize) = self
            .windows
            .get_mut(&id)
            .and_then(|window| window.resize.as_mut())
        {
            resize.sent = Some(request);
        }
    }

    /// Called only after the adapter has associated this commit with its ACK.
    pub fn commit_size(&mut self, id: WindowId, size: Size) {
        if let Some(window) = self.windows.get_mut(&id) {
            if let Some(resize) = window.resize {
                if resize.edges.left() {
                    window.position.x = clamp_coordinate(
                        i64::from(resize.initial.position.x)
                            + i64::from(resize.initial.size.width.get())
                            - i64::from(size.width.get()),
                    );
                }
                if resize.edges.top() {
                    window.position.y = clamp_coordinate(
                        i64::from(resize.initial.position.y)
                            + i64::from(resize.initial.size.height.get())
                            - i64::from(size.height.get()),
                    );
                }
            }
            window.size = Some(size);
        }
    }
    pub fn finish_resize(&mut self, id: WindowId) {
        if let Some(window) = self.windows.get_mut(&id) {
            window.resize = None;
        }
    }
}

fn clamp_coordinate(value: i64) -> i32 {
    value.clamp(i64::from(i32::MIN), i64::from(i32::MAX)) as i32
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn removed_ids_are_stale_and_never_reused() -> Result<(), IdExhausted> {
        let mut desktop = Desktop::default();
        let first = desktop.create()?;
        assert!(desktop.remove(first).is_some());
        assert!(desktop.remove(first).is_none());
        let second = desktop.create()?;
        assert!(first != second);
        assert!(desktop.get(first).is_none());
        assert!(!desktop.unmap(first));
        Ok(())
    }

    #[test]
    fn id_exhaustion_does_not_wrap_or_recycle() -> Result<(), IdExhausted> {
        let mut desktop = Desktop {
            next_id: NonZeroU32::new(u32::MAX),
            ..Desktop::default()
        };
        let last = desktop.create()?;
        assert_eq!(last.get(), u32::MAX);
        assert!(desktop.create().is_err());
        desktop.remove(last);
        assert!(desktop.create().is_err());
        Ok(())
    }

    #[test]
    fn mapping_geometry_focus_and_unmap_are_consistent() -> Result<(), Box<dyn Error>> {
        let mut desktop = Desktop::default();
        let first = desktop.create()?;
        let second = desktop.create()?;
        assert!(!desktop.focus(Some(first)));
        let size = Size::new(320, 200).ok_or("invalid size")?;
        let position = Position { x: 12, y: 16 };
        assert!(desktop.map(first, position, size, Some(OutputId::Nested)));
        assert!(desktop.focus(Some(first)));
        assert!(!desktop.focus(Some(second)));
        assert_eq!(desktop.focused(), Some(first));
        let window = desktop.get(first).ok_or("missing window")?;
        assert_eq!(window.position, position);
        assert_eq!(window.size, Some(size));
        assert_eq!(window.output, Some(OutputId::Nested));
        assert!(desktop.map(second, Position::default(), size, None));
        assert!(desktop.focus(Some(second)));
        assert_eq!(desktop.focused(), Some(second));
        assert!(!desktop.get(first).ok_or("missing window")?.focused);
        assert!(desktop.unmap(second));
        // Stage 3 restores the topmost remaining mapped window.
        assert_eq!(desktop.focused(), Some(first));
        assert!(desktop.focus(Some(first)));
        desktop.remove(first);
        assert_eq!(desktop.focused(), None);
        assert!(Size::new(0, 200).is_none());
        assert!(Size::new(200, 0).is_none());
        Ok(())
    }

    #[test]
    fn stacking_cascade_and_fallback_survive_middle_removal() -> Result<(), Box<dyn Error>> {
        let mut desktop = Desktop::default();
        let ids = [desktop.create()?, desktop.create()?, desktop.create()?];
        let bounds = Size::new(800, 600).ok_or("size")?;
        for id in ids {
            let (position, size) = desktop.placement(id, bounds).ok_or("placement")?;
            assert!(position.x >= 0 && position.y >= 0);
            assert!(position.x as u32 + size.width.get() <= 800);
            assert!(position.y as u32 + size.height.get() <= 600);
            desktop.map(id, position, size, Some(OutputId::Nested));
            desktop.focus(Some(id));
        }
        assert_eq!(desktop.stacking(), &ids);
        desktop.focus(Some(ids[0]));
        assert_eq!(desktop.stacking(), &[ids[1], ids[2], ids[0]]);
        desktop.remove(ids[1]);
        desktop.remove(ids[0]);
        assert_eq!(desktop.focused(), Some(ids[2]));
        desktop.unmap(ids[2]);
        assert!(desktop.stacking().is_empty());
        assert_eq!(desktop.focused(), None);
        Ok(())
    }

    #[test]
    fn resize_edges_limits_anchor_and_coalescing() -> Result<(), Box<dyn Error>> {
        for bits in [1, 2, 4, 5, 6, 8, 9, 10] {
            let mut desktop = Desktop::default();
            let id = desktop.create()?;
            let initial = Size::new(300, 200).ok_or("size")?;
            desktop.map(id, Position { x: 100, y: 100 }, initial, None);
            desktop.focus(Some(id));
            let edges = Edges::new(bits).ok_or("edges")?;
            assert!(desktop.begin_resize(id, Position { x: 50, y: 50 }, edges));
            let hints = SizeHints {
                min: (120, 80),
                max: (450, 350),
            };
            desktop.drag_to(
                Position {
                    x: i32::MIN,
                    y: i32::MAX,
                },
                hints,
            );
            let request = desktop.resize_request(id).ok_or("request")?;
            assert!((120..=450).contains(&request.0.width.get()));
            assert!((80..=350).contains(&request.0.height.get()));
            assert_eq!(
                desktop.get(id).ok_or("window")?.position,
                Position { x: 100, y: 100 }
            );
            desktop.mark_resize_sent(id, request);
            assert!(desktop.resize_request(id).is_none());
            // Actual client size may differ from the suggestion; keep opposite edges fixed.
            let actual = Size::new(240, 160).ok_or("size")?;
            desktop.commit_size(id, actual);
            let position = desktop.get(id).ok_or("window")?.position;
            assert_eq!(position.x, if edges.left() { 160 } else { 100 });
            assert_eq!(position.y, if edges.top() { 140 } else { 100 });
            desktop.finish_interaction();
            assert!(desktop.interaction_window().is_none());
            assert!(!desktop.resize_request(id).ok_or("final request")?.1);
            desktop.finish_resize(id);
            assert!(desktop.resize_request(id).is_none());
        }
        assert!(Edges::new(0).is_none());
        assert!(Edges::new(15).is_none());
        Ok(())
    }

    #[test]
    fn move_focus_guard_extremes_and_lifetime_cancellation() -> Result<(), Box<dyn Error>> {
        let mut desktop = Desktop::default();
        let a = desktop.create()?;
        let b = desktop.create()?;
        let size = Size::new(300, 200).ok_or("size")?;
        for id in [a, b] {
            desktop.map(id, Position::default(), size, None);
        }
        desktop.focus(Some(a));
        assert!(desktop.begin_move(
            a,
            Position {
                x: i32::MIN,
                y: i32::MIN
            }
        ));
        assert!(!desktop.focus(Some(b)));
        desktop.drag_to(
            Position {
                x: i32::MAX,
                y: i32::MAX,
            },
            SizeHints::default(),
        );
        assert_eq!(desktop.get(a).ok_or("window")?.position.x, i32::MAX);
        desktop.unmap(a);
        assert_eq!(desktop.interaction_window(), None);
        assert_eq!(desktop.focused(), Some(b));
        assert!(desktop.begin_resize(b, Position::default(), Edges::new(5).ok_or("edge")?));
        desktop.remove(b);
        assert_eq!(desktop.interaction_window(), None);
        let extreme = Size::new(u32::MAX, u32::MAX).ok_or("size")?;
        let c = desktop.create()?;
        assert!(desktop.placement(c, extreme).is_some());
        Ok(())
    }
}
