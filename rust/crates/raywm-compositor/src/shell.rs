//! XDG lifecycle adapter. Created roles enter Space only after an ACKed buffer
//! commit. The custom surface dispatch retains the public XDG error resource;
//! all protocol requests still run through Smithay's versioned implementation.

use raywm_core::windows::{Position, Size, WindowId};
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
}

impl State {
    pub fn validate_window_commit(&self, surface: &WlSurface) {
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
                toplevel.reset_initial_configure_sent();
                tracing::info!(window = view.id.get(), "Window unmapped");
            } else if root == *surface && view.initial.is_none() {
                // Initial configure follows the initial bufferless commit,
                // never get_toplevel. Remap performs the handshake again.
                toplevel.with_pending_state(|state| state.size = None);
                view.initial = Some(toplevel.send_configure());
                tracing::info!(window = view.id.get(), "Initial configure sent");
            }
        } else if view.configured {
            let geometry = view.window.geometry();
            if let Some(size) =
                Size::new(geometry.size.w.max(0) as u32, geometry.size.h.max(0) as u32)
            {
                self.desktop.map(view.id, Position::default(), size, None);
                self.space.map_element(view.window.clone(), (0, 0), false);
                if !was_mapped {
                    tracing::info!(window = view.id.get(), "Window mapped");
                }
            }
        }
        self.redraw = true;
        self.space.refresh();
    }

    pub fn remove_window(&mut self, surface: &WlSurface) {
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
        self.space.refresh();
        self.redraw = true;
        tracing::info!(window = view.id.get(), "Window destroyed");
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
                });
            }
            Err(error) => {
                tracing::error!(%error, "Cannot create window");
                surface.send_close();
            }
        }
    }

    fn ack_configure(&mut self, surface: WlSurface, configure: Configure) {
        let Configure::Toplevel(configure) = configure else {
            return;
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
    fn new_popup(&mut self, surface: PopupSurface, _: PositionerState) {
        surface.send_popup_done();
    }
    fn grab(
        &mut self,
        surface: PopupSurface,
        _: smithay::reexports::wayland_server::protocol::wl_seat::WlSeat,
        _: Serial,
    ) {
        surface.send_popup_done();
    }
    fn reposition_request(&mut self, surface: PopupSurface, _: PositionerState, _: u32) {
        surface.send_popup_done();
    }
}

// Keep the normal Smithay delegates except for xdg_surface, where retaining its
// resource lets the pre-commit hook report UnconfiguredBuffer on the right object.
delegate_global_dispatch!(State: [xdg_wm_base::XdgWmBase: ()] => XdgShellState);
delegate_dispatch!(State: [xdg_wm_base::XdgWmBase: XdgWmBaseUserData] => XdgShellState);
delegate_dispatch!(State: [xdg_positioner::XdgPositioner: XdgPositionerUserData] => XdgShellState);
delegate_dispatch!(State: [xdg_popup::XdgPopup: XdgShellSurfaceUserData] => XdgShellState);
delegate_dispatch!(State: [xdg_toplevel::XdgToplevel: XdgShellSurfaceUserData] => XdgShellState);

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
        let before = state.views.len();
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
    }
}
