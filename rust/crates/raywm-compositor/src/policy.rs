//! Internal command entry point. Protocol effects are applied only here and in
//! the existing configure/ACK adapter; callers receive validated core facts.
use crate::state::State;
use raywm_core::commands::{Command, CommandError, CommandResult, Effect};

impl State {
    pub fn execute_command(&mut self, command: Command) -> Result<CommandResult, CommandError> {
        // Defer commands that could redirect an implicit/explicit input grab.
        // Close remains a request to the client and never destroys its role.
        let guarded = !matches!(command, Command::CloseWindow(_) | Command::CreateWorkspace);
        if guarded
            && (self.dnd_active
                || self.popup_root.is_some()
                || self.seat.as_ref().is_some_and(|seat| {
                    seat.get_pointer().is_some_and(|p| p.is_grabbed())
                        || seat.get_keyboard().is_some_and(|k| k.is_grabbed())
                }))
        {
            return Err(CommandError::Busy);
        }
        if let Command::ResizeWindow { id, size } = &command {
            use smithay::wayland::{compositor::with_states, shell::xdg::SurfaceCachedState};
            if let Some(top) = self
                .views
                .iter()
                .find(|view| view.id == *id)
                .and_then(|view| view.window.toplevel())
            {
                let constrained = with_states(top.wl_surface(), |states| {
                    let mut cache = states.cached_state.get::<SurfaceCachedState>();
                    let hints = cache.current();
                    raywm_core::windows::SizeHints {
                        min: (
                            hints.min_size.w.max(0) as u32,
                            hints.min_size.h.max(0) as u32,
                        ),
                        max: (
                            hints.max_size.w.max(0) as u32,
                            hints.max_size.h.max(0) as u32,
                        ),
                    }
                    .constrain(i64::from(size.width.get()), i64::from(size.height.get()))
                });
                if constrained != *size {
                    return Err(CommandError::InvalidGeometry);
                }
            }
        }
        let result = self.desktop.execute(command)?;
        let hidden: Vec<_> = self
            .views
            .iter()
            .filter(|view| !self.desktop.visible(view.id))
            .filter_map(|view| view.window.toplevel().map(|top| top.wl_surface().clone()))
            .collect();
        for surface in hidden {
            self.dismiss_window_popups(&surface);
        }
        for effect in &result.effects {
            match effect {
                Effect::CloseWindow(id) => {
                    if let Some(top) = self
                        .views
                        .iter()
                        .find(|view| view.id == *id)
                        .and_then(|view| view.window.toplevel())
                    {
                        top.send_close();
                    }
                }
            }
        }
        self.sync_focus();
        self.repair_pointer_focus();
        self.reposition_popups();
        self.redraw = true;
        Ok(result)
    }
}
