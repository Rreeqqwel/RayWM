//! Smithay owns the popup tree, positioning and grab machinery. This adapter
//! retains only XDG handshake metadata and a checked core root ID.

use crate::state::State;
use raywm_core::windows::WindowId;
use smithay::{
    desktop::{
        get_popup_toplevel_coords, PopupKeyboardGrab, PopupKind, PopupManager, PopupPointerGrab,
        PopupUngrabStrategy,
    },
    input::Seat,
    reexports::{
        wayland_protocols::xdg::shell::server::{xdg_surface, xdg_wm_base},
        wayland_server::{
            protocol::{wl_seat::WlSeat, wl_surface::WlSurface},
            Resource,
        },
    },
    utils::{IsAlive, Serial, SERIAL_COUNTER},
    wayland::{
        compositor::{get_parent, with_states, BufferAssignment, SurfaceAttributes},
        shell::xdg::{PopupSurface, PositionerState},
    },
};

pub struct PopupEntry {
    pub surface: PopupSurface,
    pub xdg_surface: Option<xdg_surface::XdgSurface>,
    pub root: Option<WindowId>,
    initial: Option<Serial>,
    configured: bool,
    dismissed: bool,
    mapped: bool,
}

fn invalid_parent(surface: &WlSurface, message: &str) {
    with_states(surface, |states| {
        if let Some(resource) = states
            .data_map
            .get::<crate::shell::ShellErrorResource>()
            .and_then(|scope| scope.0.borrow().upgrade().ok())
        {
            resource.post_error(xdg_wm_base::Error::InvalidPopupParent, message);
        }
    });
}

impl State {
    fn checked_popup_root(&self, popup: &PopupSurface) -> Option<WindowId> {
        let mut parent = popup.get_parent_surface()?;
        for _ in 0..64 {
            if !parent.alive() || parent == *popup.wl_surface() {
                return None;
            }
            if let Some(id) = self.window_id(&parent) {
                return Some(id);
            }
            parent = self
                .popup_entries
                .iter()
                .find(|entry| entry.surface.wl_surface() == &parent && !entry.dismissed)?
                .surface
                .get_parent_surface()?;
        }
        None
    }

    pub fn surface_window(&self, surface: &WlSurface) -> Option<WindowId> {
        if !surface.alive() {
            return None;
        }
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        self.window_id(&root).or_else(|| {
            self.popup_entries
                .iter()
                .find(|entry| entry.surface.wl_surface() == &root && !entry.dismissed)
                .and_then(|entry| entry.root)
        })
    }

    pub fn create_popup(&mut self, surface: PopupSurface) {
        let root = self.checked_popup_root(&surface);
        let mut entry = PopupEntry {
            surface: surface.clone(),
            xdg_surface: None,
            root,
            initial: None,
            configured: false,
            dismissed: root.is_none(),
            mapped: false,
        };
        if root.is_none()
            || self
                .popups
                .track_popup(PopupKind::Xdg(surface.clone()))
                .is_err()
        {
            if root.is_none() {
                invalid_parent(
                    surface.wl_surface(),
                    "popup parent must be a live toplevel or popup (maximum ancestry 64)",
                );
            } else {
                surface.send_popup_done();
            }
            entry.dismissed = true;
        } else {
            self.position_popup(&surface, None);
        }
        self.popup_entries.push(entry);
        self.redraw = true;
    }

    pub fn position_popup(
        &self,
        popup: &PopupSurface,
        positioner: Option<PositionerState>,
    ) -> bool {
        if self.popup_entries.iter().any(|entry| {
            entry.surface == *popup
                && (entry.dismissed || self.popups.find_popup(popup.wl_surface()).is_none())
        }) {
            return false;
        }
        let root = self.checked_popup_root(popup);
        if root.is_none() {
            return false;
        }
        // parent() locks the role too; never call it inside with_pending_state.
        let parent_offset = get_popup_toplevel_coords(&PopupKind::Xdg(popup.clone()));
        let geometry = root
            .and_then(|id| self.views.iter().find(|view| view.id == id))
            .and_then(|view| self.space.element_geometry(&view.window));
        let output = self
            .output
            .as_ref()
            .and_then(|output| self.space.output_geometry(output));
        popup.with_pending_state(|state| {
            if let Some(positioner) = positioner {
                state.positioner = positioner;
            }
            state.geometry = state.positioner.get_geometry();
            if let (Some(window), Some(mut bounds)) = (geometry, output) {
                bounds.loc -= window.loc;
                bounds.loc -= parent_offset;
                state.geometry = state.positioner.get_unconstrained_geometry(bounds);
            }
        });
        true
    }

    pub fn validate_popup_commit(&mut self, surface: &WlSurface) {
        if let Some(entry) = self
            .popup_entries
            .iter()
            .find(|entry| entry.surface.wl_surface() == surface)
        {
            let attaching = with_states(surface, |states| {
                matches!(
                    states
                        .cached_state
                        .get::<SurfaceAttributes>()
                        .pending()
                        .buffer,
                    Some(BufferAssignment::NewBuffer(_))
                )
            });
            let parent_mapped = entry.surface.get_parent_surface().is_some_and(|parent| {
                self.window_id(&parent)
                    .and_then(|id| self.desktop.get(id))
                    .is_some_and(|model| model.mapped)
                    || self.popup_entries.iter().any(|entry| {
                        entry.surface.wl_surface() == &parent && entry.mapped && !entry.dismissed
                    })
            });
            if attaching && (!entry.configured || entry.dismissed) {
                if let Some(xdg) = &entry.xdg_surface {
                    xdg.post_error(
                        xdg_surface::Error::UnconfiguredBuffer,
                        "popup requires an ACKed configure and must not be dismissed",
                    );
                }
            } else if attaching && !parent_mapped {
                invalid_parent(surface, "popup parent must be mapped before its child");
            }
        }
    }

    pub fn ack_popup(&mut self, surface: &WlSurface, serial: Serial) {
        if let Some(entry) = self
            .popup_entries
            .iter_mut()
            .find(|entry| entry.surface.wl_surface() == surface)
        {
            if entry.initial.is_some_and(|initial| serial >= initial) {
                entry.configured = true;
            }
        }
    }

    pub fn commit_popup(&mut self, surface: &WlSurface) {
        self.popups.commit(surface);
        let mut dismiss = None;
        if let Some(entry) = self
            .popup_entries
            .iter_mut()
            .find(|entry| entry.surface.wl_surface() == surface)
        {
            if entry.dismissed {
                return;
            }
            let buffered =
                smithay::backend::renderer::utils::with_renderer_surface_state(surface, |state| {
                    state.buffer().is_some()
                })
                .unwrap_or(false);
            if !buffered && entry.initial.is_none() {
                match entry.surface.send_configure() {
                    Ok(serial) => entry.initial = Some(serial),
                    Err(error) => {
                        tracing::warn!(%error,"Cannot configure popup");
                        entry.surface.send_popup_done();
                        entry.dismissed = true;
                    }
                }
            }
            if entry.mapped && !buffered {
                dismiss = Some(entry.surface.clone());
            }
            entry.mapped = buffered && entry.configured && !entry.dismissed;
            self.redraw = true;
            self.space.refresh();
        }
        if let Some(popup) = dismiss {
            self.reject_popup(&popup);
        }
    }

    pub fn dismiss_window_popups(&mut self, surface: &WlSurface) {
        let Some(id) = self.window_id(surface) else {
            return;
        };
        if self.popup_root == Some(id) {
            self.end_popup_grab();
            self.refresh_popups();
        }
        let popups = self
            .popup_entries
            .iter()
            .filter(|e| e.root == Some(id) && !e.dismissed)
            .map(|e| e.surface.clone())
            .collect::<Vec<_>>();
        for popup in popups {
            self.reject_popup(&popup);
            self.refresh_popups();
        }
        self.redraw = true;
    }

    pub fn remove_popup(&mut self, surface: &WlSurface) {
        if let Some(index) = self
            .popup_entries
            .iter()
            .position(|entry| entry.surface.wl_surface() == surface)
        {
            let entry = self.popup_entries.remove(index);
            if let Some(root) = entry
                .root
                .and_then(|id| self.views.iter().find(|view| view.id == id))
                .and_then(|view| view.window.toplevel())
            {
                if root.wl_surface().alive() {
                    let _ = PopupManager::dismiss_popup(
                        root.wl_surface(),
                        &PopupKind::Xdg(entry.surface),
                    );
                }
            }
            self.refresh_popups();
            self.redraw = true;
        }
    }

    pub fn grab_popup(&mut self, popup: PopupSurface, resource: WlSeat, serial: Serial) {
        let Some(seat) = self.seat.clone() else {
            self.reject_popup(&popup);
            return;
        };
        if Seat::<Self>::from_resource(&resource).as_ref() != Some(&seat)
            || self.desktop.interaction_window().is_some()
        {
            self.reject_popup(&popup);
            return;
        }
        let Some(root_id) = self.checked_popup_root(&popup) else {
            self.reject_popup(&popup);
            return;
        };
        let Some(root) = self
            .views
            .iter()
            .find(|view| view.id == root_id)
            .and_then(|view| view.window.toplevel())
            .map(|top| top.wl_surface().clone())
        else {
            return;
        };
        let Some(pointer) = seat.get_pointer() else {
            self.reject_popup(&popup);
            return;
        };
        let nested = self.popup_root == Some(root_id)
            && self.popup_grab.as_ref().is_some_and(|grab| {
                grab.serial() == serial || grab.previous_serial() == Some(serial)
            });
        let pressed = pointer.has_grab(serial)
            && pointer.grab_start_data().is_some_and(|start| {
                start.focus.as_ref().is_some_and(|(surface, _)| {
                    self.surface_window(surface) == Some(root_id)
                        && surface.id().same_client_as(&popup.wl_surface().id())
                }) && self.pressed_buttons.contains(&start.button)
            });
        let keyed = self
            .key_grant
            .as_ref()
            .is_some_and(|(grant, target, when)| {
                *grant == serial
                    && when.elapsed() < std::time::Duration::from_secs(5)
                    && self.surface_window(target) == Some(root_id)
                    && target.id().same_client_as(&popup.wl_surface().id())
            });
        if self.desktop.focused() != Some(root_id) || (!nested && !pressed && !keyed) {
            self.reject_popup(&popup);
            return;
        }
        let Some(keyboard) = seat.get_keyboard() else {
            self.reject_popup(&popup);
            return;
        };
        match self
            .popups
            .grab_popup(root, PopupKind::Xdg(popup.clone()), &seat, serial)
        {
            Ok(grab) => {
                keyboard.set_focus(self, grab.current_grab(), serial);
                keyboard.set_grab(self, PopupKeyboardGrab::new(&grab), serial);
                pointer.set_grab(
                    self,
                    PopupPointerGrab::new(&grab),
                    serial,
                    smithay::input::pointer::Focus::Keep,
                );
                self.popup_grab = Some(grab);
                self.popup_root = Some(root_id);
                self.key_grant = None;
                self.redraw = true;
            }
            Err(error) => {
                tracing::warn!(%error,"Popup grab rejected");
                self.reject_popup(&popup);
            }
        }
    }

    fn reject_popup(&mut self, popup: &PopupSurface) {
        if let Some(entry) = self
            .popup_entries
            .iter_mut()
            .find(|entry| entry.surface == *popup)
        {
            if entry.dismissed {
                return;
            }
            entry.dismissed = true;
            if let Some(root) = entry
                .root
                .and_then(|id| self.views.iter().find(|v| v.id == id))
                .and_then(|v| v.window.toplevel())
            {
                if root.wl_surface().alive() && self.popups.find_popup(popup.wl_surface()).is_some()
                {
                    let _ = PopupManager::dismiss_popup(
                        root.wl_surface(),
                        &PopupKind::Xdg(popup.clone()),
                    );
                } else {
                    popup.send_popup_done();
                }
            } else {
                popup.send_popup_done();
            }
        }
        self.redraw = true;
    }

    pub fn end_popup_grab(&mut self) {
        if let Some(mut grab) = self.popup_grab.take() {
            grab.ungrab(PopupUngrabStrategy::All);
        }
        self.popup_root = None;
        if let Some(keyboard) = self.seat.as_ref().and_then(|seat| seat.get_keyboard()) {
            keyboard.unset_grab(self);
        }
        if let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) {
            let time = smithay::utils::Clock::<smithay::utils::Monotonic>::new()
                .now()
                .as_millis();
            pointer.unset_grab(self, SERIAL_COUNTER.next_serial(), time);
        }
    }

    pub fn refresh_popups(&mut self) {
        self.popups.cleanup();
        for entry in &mut self.popup_entries {
            if !entry.dismissed && self.popups.find_popup(entry.surface.wl_surface()).is_none() {
                entry.dismissed = true;
                self.redraw = true;
            }
        }
        let ended = self.popup_grab.as_ref().is_some_and(|grab| {
            grab.has_ended()
                || grab
                    .current_grab()
                    .is_none_or(|surface| self.popups.find_popup(&surface).is_none())
        });
        if ended {
            self.end_popup_grab();
            self.sync_focus();
            self.redraw = true;
        } else if let Some(target) = self
            .popup_grab
            .as_ref()
            .and_then(|grab| grab.current_grab())
        {
            if let Some(keyboard) = self.seat.as_ref().and_then(|seat| seat.get_keyboard()) {
                keyboard.set_focus(self, Some(target), SERIAL_COUNTER.next_serial());
            }
        }
    }
}
