//! XDG lifecycle adapter. Created roles enter Space only after an ACKed buffer
//! commit. The custom surface dispatch retains the public XDG error resource;
//! all protocol requests still run through Smithay's versioned implementation.

use raywm_core::windows::{OutputId, Position, Size, WindowId};
use smithay::{
    backend::renderer::utils::with_renderer_surface_state,
    desktop::Window,
    reexports::{
        wayland_protocols::xdg::shell::server::{
            xdg_popup, xdg_positioner, xdg_surface, xdg_toplevel, xdg_wm_base,
        },
        wayland_server::{
            delegate_dispatch, delegate_global_dispatch, protocol::wl_surface::WlSurface, Client,
            DataInit, Dispatch, DisplayHandle, Resource,
        },
    },
    utils::Serial,
    wayland::{
        compositor::{
            get_parent, is_sync_subsurface, with_states, BufferAssignment, SurfaceAttributes,
        },
        shell::xdg::{
            Configure, PopupSurface, PositionerState, ToplevelSurface, XdgPositionerUserData,
            XdgShellHandler, XdgShellState, XdgShellSurfaceUserData, XdgSurfaceUserData,
            XdgWmBaseUserData,
        },
    },
};

use crate::state::State;

pub struct View {
    pub id: WindowId,
    pub window: Window,
    xdg_surface: Option<xdg_surface::XdgSurface>,
    initial: Option<Serial>,
    configured: bool,
    acked: Option<Serial>,
    pub resize_flight: Option<(Serial, bool)>,
}

// Tied to wl_surface lifetime, so errors use the originating wm_base without
// a parallel client registry or access to Smithay's private user-data fields.
pub struct ShellErrorResource(
    pub std::cell::RefCell<smithay::reexports::wayland_server::Weak<xdg_wm_base::XdgWmBase>>,
);

impl State {
    /// Space owns protocol/render handles; core alone owns logical geometry and order.
    pub fn sync_scene(&mut self) {
        for id in self.desktop.stacking() {
            if let (Some(model), Some(view)) = (
                self.desktop.get(*id),
                self.views.iter().find(|view| view.id == *id),
            ) {
                self.space.map_element(
                    view.window.clone(),
                    (model.position.x, model.position.y),
                    false,
                );
            }
        }
        self.space.refresh();
    }

    pub fn window_id(&self, surface: &WlSurface) -> Option<WindowId> {
        self.views
            .iter()
            .find(|view| {
                view.window
                    .toplevel()
                    .is_some_and(|top| top.wl_surface() == surface)
            })
            .map(|view| view.id)
    }

    /// One configure in flight per window. Motions coalesce in core desired
    /// state; ACK alone does not release this slot until its surface commit.
    pub fn flush_geometry(&mut self) {
        for view in &mut self.views {
            if view.resize_flight.is_some() {
                continue;
            }
            if let (Some(request), Some(top)) =
                (self.desktop.resize_request(view.id), view.window.toplevel())
            {
                top.with_pending_state(|state| {
                    state.size =
                        Some((request.0.width.get() as i32, request.0.height.get() as i32).into());
                    if request.1 {
                        state.states.set(xdg_toplevel::State::Resizing);
                    } else {
                        state.states.unset(xdg_toplevel::State::Resizing);
                    }
                });
                let serial = top.send_configure();
                view.resize_flight = Some((serial, !request.1));
                self.desktop.mark_resize_sent(view.id, request);
            }
        }
    }

    pub fn validate_window_commit(&mut self, surface: &WlSurface) {
        self.validate_popup_commit(surface);
        let Some(view) = self.views.iter().find(|view| {
            view.window
                .toplevel()
                .is_some_and(|t| t.wl_surface() == surface)
        }) else {
            return;
        };
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
        if attaching && !view.configured {
            if let Some(xdg) = &view.xdg_surface {
                xdg.post_error(
                    xdg_surface::Error::UnconfiguredBuffer,
                    "ACK the initial configure before committing a buffer (also after unmap)",
                );
            }
        }
    }

    pub fn commit_window(&mut self, surface: &WlSurface) {
        if is_sync_subsurface(surface) {
            return;
        }
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        let Some(index) = self.views.iter().position(|view| {
            view.window
                .toplevel()
                .is_some_and(|t| t.wl_surface() == &root)
        }) else {
            return;
        };
        let view = &mut self.views[index];
        let Some(toplevel) = view.window.toplevel() else {
            return;
        };
        view.window.on_commit();
        let mapped =
            with_renderer_surface_state(&root, |state| state.buffer().is_some()).unwrap_or(false);
        let was_mapped = self
            .desktop
            .get(view.id)
            .is_some_and(|window| window.mapped);
        if !mapped {
            if was_mapped {
                self.space.unmap_elem(&view.window);
                self.desktop.unmap(view.id);
                view.configured = false;
                view.initial = None;
                view.acked = None;
                view.resize_flight = None;
                toplevel.reset_initial_configure_sent();
                toplevel
                    .with_pending_state(|state| state.states.unset(xdg_toplevel::State::Resizing));
                tracing::info!(window = view.id.get(), "Window unmapped");
            } else if root == *surface && view.initial.is_none() {
                // Initial configure follows the initial bufferless commit,
                // never get_toplevel. Remap performs the handshake again.
                let size = self
                    .output
                    .as_ref()
                    .and_then(|output| output.current_mode())
                    .and_then(|mode| {
                        let bounds =
                            Size::new(mode.size.w.max(1) as u32, mode.size.h.max(1) as u32)?;
                        self.desktop.placement(view.id, bounds).map(|(_, size)| {
                            (size.width.get() as i32, size.height.get() as i32).into()
                        })
                    });
                toplevel.with_pending_state(|state| state.size = size);
                view.initial = Some(toplevel.send_configure());
                tracing::info!(window = view.id.get(), "Initial configure sent");
            }
        } else if view.configured {
            let geometry = view.window.geometry();
            if let Some(size) =
                Size::new(geometry.size.w.max(0) as u32, geometry.size.h.max(0) as u32)
            {
                let position = if was_mapped {
                    self.desktop
                        .get(view.id)
                        .map(|window| window.position)
                        .unwrap_or_default()
                } else {
                    let bounds = self
                        .output
                        .as_ref()
                        .and_then(|output| output.current_mode())
                        .and_then(|mode| {
                            Size::new(mode.size.w.max(1) as u32, mode.size.h.max(1) as u32)
                        })
                        .unwrap_or(size);
                    let (position, _) = self
                        .desktop
                        .placement(view.id, bounds)
                        .unwrap_or((Position::default(), size));
                    Position {
                        x: position
                            .x
                            .min(bounds.width.get().saturating_sub(size.width.get()) as i32),
                        y: position
                            .y
                            .min(bounds.height.get().saturating_sub(size.height.get()) as i32),
                    }
                };
                self.desktop.map(
                    view.id,
                    position,
                    size,
                    self.output.as_ref().map(|_| OutputId::Nested),
                );
                let resized = view
                    .resize_flight
                    .filter(|(serial, _)| view.acked.is_some_and(|acked| acked >= *serial));
                if resized.is_some() || view.resize_flight.is_none() {
                    self.desktop.commit_size(view.id, size);
                }
                if let Some((_, finished)) = resized {
                    view.resize_flight = None;
                    if finished {
                        self.desktop.finish_resize(view.id);
                    }
                }
                if !was_mapped {
                    tracing::info!(window = view.id.get(), "Window mapped");
                    let grabbed = self.seat.as_ref().is_some_and(|seat| {
                        seat.get_pointer()
                            .is_some_and(|pointer| pointer.is_grabbed())
                            || seat
                                .get_keyboard()
                                .is_some_and(|keyboard| keyboard.is_grabbed())
                    });
                    if self.host_focused && !grabbed {
                        self.desktop.focus(Some(view.id));
                    } else if let Some(focused) = self.desktop.focused() {
                        self.desktop.raise(focused);
                    }
                }
            }
        }
        if !mapped && was_mapped {
            self.dismiss_window_popups(&root);
        }
        self.redraw = true;
        self.sync_scene();
        self.sync_focus();
        self.repair_pointer_focus();
    }

    pub fn remove_window(&mut self, surface: &WlSurface) {
        self.dismiss_window_popups(surface);
        let Some(index) = self.views.iter().position(|view| {
            view.window
                .toplevel()
                .is_some_and(|t| t.wl_surface() == surface)
        }) else {
            return;
        };
        let view = self.views.remove(index);
        self.space.unmap_elem(&view.window);
        self.desktop.remove(view.id);
        self.sync_scene();
        self.redraw = true;
        tracing::info!(window = view.id.get(), "Window destroyed");
        self.sync_focus();
        self.repair_pointer_focus();
    }

    #[cfg(feature = "winit")]
    pub fn request_window_size(
        &mut self,
        size: smithay::utils::Size<i32, smithay::utils::Logical>,
    ) {
        for view in &self.views {
            if view.initial.is_some()
                && self
                    .desktop
                    .get(view.id)
                    .is_some_and(|model| model.resize.is_none())
            {
                if let Some(toplevel) = view.window.toplevel() {
                    let current = self.desktop.get(view.id).and_then(|model| model.size);
                    let suggested = current.map(|current| {
                        (
                            current.width.get().min(size.w.max(1) as u32) as i32,
                            current.height.get().min(size.h.max(1) as u32) as i32,
                        )
                            .into()
                    });
                    if current.is_some_and(|current| {
                        current.width.get() > size.w.max(1) as u32
                            || current.height.get() > size.h.max(1) as u32
                    }) {
                        toplevel.with_pending_state(|state| state.size = suggested);
                        toplevel.send_pending_configure();
                    }
                }
            }
        }
    }
}

impl XdgShellHandler for State {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        match self.desktop.create() {
            Ok(id) => {
                tracing::info!(window = id.get(), "Window role created (unmapped)");
                self.views.push(View {
                    id,
                    window: Window::new_wayland_window(surface),
                    xdg_surface: None,
                    initial: None,
                    configured: false,
                    acked: None,
                    resize_flight: None,
                });
            }
            Err(error) => {
                tracing::error!(%error, "Cannot create window");
                surface.send_close();
            }
        }
    }

    fn ack_configure(&mut self, surface: WlSurface, configure: Configure) {
        let configure = match configure {
            Configure::Toplevel(configure) => configure,
            Configure::Popup(configure) => {
                self.ack_popup(&surface, configure.serial);
                return;
            }
        };
        if let Some(view) = self.views.iter_mut().find(|view| {
            view.window
                .toplevel()
                .is_some_and(|t| t.wl_surface() == &surface)
        }) {
            if view
                .initial
                .is_some_and(|initial| configure.serial >= initial)
            {
                view.configured = true;
                view.acked = Some(configure.serial);
                tracing::info!(
                    window = view.id.get(),
                    serial = u32::from(configure.serial),
                    "Configure acknowledged"
                );
            }
        }
    }

    fn toplevel_destroyed(&mut self, surface: ToplevelSurface) {
        self.remove_window(surface.wl_surface());
    }
    fn move_request(
        &mut self,
        surface: ToplevelSurface,
        seat: smithay::reexports::wayland_server::protocol::wl_seat::WlSeat,
        serial: Serial,
    ) {
        self.start_operation(surface, seat, serial, None);
    }
    fn resize_request(
        &mut self,
        surface: ToplevelSurface,
        seat: smithay::reexports::wayland_server::protocol::wl_seat::WlSeat,
        serial: Serial,
        edges: xdg_toplevel::ResizeEdge,
    ) {
        if let Some(edges) = raywm_core::windows::Edges::new(edges as u32) {
            self.start_operation(surface, seat, serial, Some(edges));
        }
    }
    fn new_popup(&mut self, surface: PopupSurface, _: PositionerState) {
        self.create_popup(surface);
    }
    fn grab(
        &mut self,
        surface: PopupSurface,
        seat: smithay::reexports::wayland_server::protocol::wl_seat::WlSeat,
        serial: Serial,
    ) {
        self.grab_popup(surface, seat, serial);
    }
    fn reposition_request(
        &mut self,
        surface: PopupSurface,
        positioner: PositionerState,
        token: u32,
    ) {
        if self.position_popup(&surface, Some(positioner)) {
            surface.send_repositioned(token);
        }
    }
    fn popup_destroyed(&mut self, surface: PopupSurface) {
        self.remove_popup(surface.wl_surface());
    }
}

// Keep the normal Smithay delegates except for xdg_surface, where retaining its
// resource lets the pre-commit hook report UnconfiguredBuffer on the right object.
delegate_global_dispatch!(State: [xdg_wm_base::XdgWmBase: ()] => XdgShellState);
delegate_dispatch!(State: [xdg_positioner::XdgPositioner: XdgPositionerUserData] => XdgShellState);
delegate_dispatch!(State: [xdg_popup::XdgPopup: XdgShellSurfaceUserData] => XdgShellState);
delegate_dispatch!(State: [xdg_toplevel::XdgToplevel: XdgShellSurfaceUserData] => XdgShellState);

impl Dispatch<xdg_wm_base::XdgWmBase, XdgWmBaseUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &xdg_wm_base::XdgWmBase,
        request: xdg_wm_base::Request,
        data: &XdgWmBaseUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        if let xdg_wm_base::Request::GetXdgSurface { surface, .. } = &request {
            with_states(surface, |states| {
                states.data_map.insert_if_missing(|| {
                    ShellErrorResource(std::cell::RefCell::new(resource.downgrade()))
                });
                if let Some(scope) = states.data_map.get::<ShellErrorResource>() {
                    scope.0.replace(resource.downgrade());
                }
            });
        }
        <XdgShellState as Dispatch<xdg_wm_base::XdgWmBase, XdgWmBaseUserData, Self>>::request(
            state, client, resource, request, data, dh, init,
        );
    }

    fn destroyed(
        state: &mut Self,
        client: smithay::reexports::wayland_server::backend::ClientId,
        resource: &xdg_wm_base::XdgWmBase,
        data: &XdgWmBaseUserData,
    ) {
        <XdgShellState as Dispatch<xdg_wm_base::XdgWmBase, XdgWmBaseUserData, Self>>::destroyed(
            state, client, resource, data,
        );
    }
}

impl Dispatch<xdg_surface::XdgSurface, XdgSurfaceUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &xdg_surface::XdgSurface,
        request: xdg_surface::Request,
        data: &XdgSurfaceUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        let creating = matches!(request, xdg_surface::Request::GetToplevel { .. });
        let creating_popup = matches!(request, xdg_surface::Request::GetPopup { .. });
        let before = state.views.len();
        let before_popup = state.popup_entries.len();
        <XdgShellState as Dispatch<xdg_surface::XdgSurface, XdgSurfaceUserData, Self>>::request(
            state, client, resource, request, data, dh, init,
        );
        // Smithay calls new_toplevel synchronously during this request. There
        // is no nested dispatch; allocation failure does not append an entry.
        if creating && state.views.len() > before {
            if let Some(view) = state.views.last_mut() {
                view.xdg_surface = Some(resource.clone());
            }
        }
        if creating_popup && state.popup_entries.len() > before_popup {
            if let Some(popup) = state.popup_entries.last_mut() {
                popup.xdg_surface = Some(resource.clone());
            }
        }
    }
}
