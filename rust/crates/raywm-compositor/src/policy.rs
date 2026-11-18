//! Internal command entry point. Protocol effects are applied only here and in
//! the existing configure/ACK adapter; callers receive validated core facts.
use crate::state::State;
use raywm_core::commands::{Command, CommandError, CommandResult, Effect};

impl State {
    pub fn execute_command(&mut self, command: Command) -> Result<CommandResult, CommandError> {
        // Defer commands that could redirect an implicit/explicit input grab.
        // Close remains a request to the client and never destroys its role.
        let guarded = !matches!(command, Command::CloseWindow(_) | Command::CreateWorkspace);
        let popup_switch = self.popup_root.is_some() && is_workspace_switch(&command);
        if guarded
            && (self.dnd_active
                || !popup_switch
                    && (self.popup_root.is_some()
                        || self.seat.as_ref().is_some_and(|seat| {
                            seat.get_pointer().is_some_and(|p| p.is_grabbed())
                                || seat.get_keyboard().is_some_and(|k| k.is_grabbed())
                        })))
        {
            return Err(CommandError::Busy);
        }
        if let Command::ResizeWindow { id, size } = &command {
            if let Some(top) = self
                .views
                .iter()
                .find(|view| view.id == *id)
                .and_then(|view| view.window.toplevel())
            {
                let constrained = crate::shell::size_hints(top.wl_surface())
                    .constrain(i64::from(size.width.get()), i64::from(size.height.get()));
                if constrained != *size {
                    return Err(CommandError::InvalidGeometry);
                }
            }
        }
        let result = self.desktop.execute(command)?;
        if popup_switch {
            if let Some(root) = self.popup_root.and_then(|id| self.desktop.get(id)) {
                if root.workspace != self.desktop.active_workspace() {
                    if let Some(surface) = self
                        .views
                        .iter()
                        .find(|view| view.id == root.id)
                        .and_then(|view| view.window.toplevel())
                        .map(|top| top.wl_surface().clone())
                    {
                        self.dismiss_window_popups(&surface);
                    }
                }
            }
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

pub(crate) fn is_workspace_switch(command: &Command) -> bool {
    matches!(
        command,
        Command::ActivateWorkspace(_) | Command::NextWorkspace | Command::PreviousWorkspace
    )
}
