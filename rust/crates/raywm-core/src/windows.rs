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
}

impl Default for Desktop {
    fn default() -> Self {
        Self {
            next_id: NonZeroU32::new(1),
            windows: BTreeMap::new(),
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
            },
        );
        Ok(id)
    }

    pub fn get(&self, id: WindowId) -> Option<&WindowState> {
        self.windows.get(&id)
    }

    pub fn remove(&mut self, id: WindowId) -> Option<WindowState> {
        self.windows.remove(&id)
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
        window.mapped = true;
        true
    }

    pub fn unmap(&mut self, id: WindowId) -> bool {
        let Some(window) = self.windows.get_mut(&id) else {
            return false;
        };
        window.mapped = false;
        window.focused = false;
        window.output = None;
        window.size = None;
        true
    }

    /// Invalid/unmapped focus requests do not disturb the current focus.
    pub fn focus(&mut self, id: Option<WindowId>) -> bool {
        if id.is_some_and(|id| !self.windows.get(&id).is_some_and(|window| window.mapped)) {
            return false;
        }
        for window in self.windows.values_mut() {
            window.focused = Some(window.id) == id;
        }
        true
    }

    pub fn focused(&self) -> Option<WindowId> {
        self.windows
            .values()
            .find(|window| window.focused)
            .map(|window| window.id)
    }
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
        assert_eq!(desktop.focused(), None);
        assert!(desktop.focus(Some(first)));
        desktop.remove(first);
        assert_eq!(desktop.focused(), None);
        assert!(Size::new(0, 200).is_none());
        assert!(Size::new(200, 0).is_none());
        Ok(())
    }
}
