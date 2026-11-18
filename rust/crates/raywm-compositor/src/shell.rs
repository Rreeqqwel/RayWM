//! XDG lifecycle adapter. Created roles enter Space only after an ACKed buffer
//! commit. The custom surface dispatch retains the public XDG error resource;
//! all protocol requests still run through Smithay's versioned implementation.

use raywm_core::{
    layout::Presentation,
    windows::{Geometry, Position, Size, SizeHints, WindowId},
};
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
            Configure, PopupSurface, PositionerState, SurfaceCachedState, ToplevelSurface,
            XdgPositionerUserData, XdgShellHandler, XdgShellState, XdgShellSurfaceUserData,
            XdgSurfaceUserData, XdgWmBaseUserData,
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
    pub managed_box: Option<Geometry>,
    managed_configure: Option<ManagedConfigure>,
    managed_flight: Option<(Serial, ManagedConfigure)>,
    queued_configure: Option<ManagedConfigure>,
    reply_to_request: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct ManagedConfigure {
    size: Size,
    tiled: bool,
    presentation: Presentation,
}

pub(crate) fn logical_rectangle(
    geometry: Geometry,
) -> smithay::utils::Rectangle<i32, smithay::utils::Logical> {
    smithay::utils::Rectangle::new(
        (geometry.position.x, geometry.position.y).into(),
        (
            geometry.size.width.get() as i32,
            geometry.size.height.get() as i32,
        )
            .into(),
    )
}

/// Read the currently committed XDG hints, never pending client requests.
pub(crate) fn size_hints(surface: &WlSurface) -> SizeHints {
    with_states(surface, |states| {
        let mut cache = states.cached_state.get::<SurfaceCachedState>();
        let hints = cache.current();
        SizeHints {
            min: (
                hints.min_size.w.max(0) as u32,
                hints.min_size.h.max(0) as u32,
            ),
            max: (
                hints.max_size.w.max(0) as u32,
                hints.max_size.h.max(0) as u32,
            ),
        }
    })
}

// Tied to wl_surface lifetime, so errors use the originating wm_base without
// a parallel client registry or access to Smithay's private user-data fields.
pub struct ShellErrorResource(
    pub std::cell::RefCell<smithay::reexports::wayland_server::Weak<xdg_wm_base::XdgWmBase>>,
);

impl State {
    #[cfg(any(feature = "winit", test))]
    pub fn observe_output(
        &mut self,
        id: raywm_core::windows::OutputId,
        output: &smithay::output::Output,
    ) -> Result<(), raywm_core::commands::CommandError> {
        use raywm_core::commands::CommandError;
        let mode = output.current_mode().ok_or(CommandError::InvalidGeometry)?;
        let location = output.current_location();
        let size: smithay::utils::Size<i32, smithay::utils::Logical> = output
            .current_transform()
            .transform_size(mode.size)
            .to_f64()
            .to_logical(output.current_scale().fractional_scale())
            .to_i32_ceil();
        let geometry = Geometry {
            position: Position {
                x: location.x,
                y: location.y,
            },
            size: Size::new(size.w.max(0) as u32, size.h.max(0) as u32)
                .ok_or(CommandError::InvalidGeometry)?,
        };
        self.desktop.update_output(id, geometry)?;
        self.space.map_output(output, location);
        self.sync_focus();
        self.repair_pointer_focus();
        self.reposition_popups();
        self.redraw = true;
        Ok(())
    }

    #[cfg(any(feature = "winit", test))]
    pub fn forget_output(
        &mut self,
        id: raywm_core::windows::OutputId,
        output: &smithay::output::Output,
    ) -> Result<(), raywm_core::commands::CommandError> {
        self.desktop.remove_output(id)?;
        self.space.unmap_output(output);
        self.sync_focus();
        self.repair_pointer_focus();
        self.reposition_popups();
        self.redraw = true;
        Ok(())
    }

    /// Space owns protocol/render handles; core alone owns logical geometry and order.
    pub fn sync_scene(&mut self) {
        // Reparent/output observations may cancel an operation in core. Drop
        // its adapter flight too; no stale resize anchor survives that change.
        for view in &mut self.views {
            if self
                .desktop
                .get(view.id)
                .is_some_and(|w| w.resize.is_none())
            {
                let had_flight = view.resize_flight.take().is_some();
                if let Some(top) = view.window.toplevel() {
                    let resizing = top.with_pending_state(|state| {
                        let resizing = state.states.contains(xdg_toplevel::State::Resizing);
                        state.states.unset(xdg_toplevel::State::Resizing);
                        resizing
                    });
                    if had_flight || resizing {
                        top.send_pending_configure();
                    }
                }
            }
        }
        let requested: std::collections::BTreeSet<_> = self
            .views
            .iter()
            .filter(|view| view.reply_to_request)
            .filter_map(|view| self.desktop.get(view.id).map(|w| w.workspace))
            .collect();
        let mut placements = std::collections::BTreeMap::new();
        for workspace in self.desktop.workspaces() {
            let request = requested.contains(&workspace.id);
            let plan = if request {
                self.desktop.workspace_plan(workspace.id)
            } else {
                self.desktop.layout_plan(workspace.id)
            };
            match plan {
                Ok(plan) => placements.extend(plan.placements.into_iter().map(|p| (p.id, p))),
                Err(error) => tracing::error!(?error, "Cannot reconcile workspace layout"),
            }
        }
        for view in &mut self.views {
            let shown = self.desktop.visible(view.id);
            let model = placements.get(&view.id);
            if !shown || !model.is_some_and(|p| p.visible) {
                view.managed_box = None;
                self.space.unmap_elem(&view.window);
            }
            if let Some(model) = model {
                let desired = (model.tiled || model.presentation != Presentation::Normal)
                    .then_some(ManagedConfigure {
                        size: model.geometry.size,
                        tiled: model.tiled,
                        presentation: model.presentation,
                    });
                if desired != view.managed_configure
                    && (shown
                        || view.reply_to_request
                        || view.managed_configure.is_some()
                        || desired.is_some_and(|config| config.tiled))
                {
                    // On return to normal floating, suggest the saved size once.
                    let config = desired.unwrap_or(ManagedConfigure {
                        size: model.geometry.size,
                        tiled: false,
                        presentation: Presentation::Normal,
                    });
                    view.queued_configure = Some(config);
                    view.managed_configure = desired;
                }
            }
        }
        let hidden: std::collections::BTreeSet<_> = self
            .popup_entries
            .iter()
            .filter(|entry| !entry.dismissed)
            .filter_map(|entry| entry.root)
            .filter(|id| !self.desktop.visible(*id))
            .collect();
        for id in hidden {
            if let Some(root) = self
                .views
                .iter()
                .find(|view| view.id == id)
                .and_then(|view| view.window.toplevel())
                .map(|top| top.wl_surface().clone())
            {
                self.dismiss_window_popups(&root);
            }
        }
        let mut order = self.desktop.stacking().to_vec();
        order.sort_by_key(|id| self.desktop.stacking_layer(*id));
        for id in order {
            let Some(model) = placements
                .get(&id)
                .filter(|p| p.visible && self.desktop.visible(id))
            else {
                continue;
            };
            let Some(view) = self.views.iter_mut().find(|view| view.id == id) else {
                continue;
            };
            let mut position = model.geometry.position;
            if model.presentation == Presentation::Fullscreen {
                // XDG permits a smaller fullscreen buffer and requires
                // centering it within the output's border fill.
                if let Some(size) = self.desktop.get(id).and_then(|w| w.size) {
                    let output = model.geometry.size;
                    position.x += (output.width.get().saturating_sub(size.width.get()) / 2) as i32;
                    position.y +=
                        (output.height.get().saturating_sub(size.height.get()) / 2) as i32;
                }
            }
            self.desktop.place_at(id, position);
            self.space
                .map_element(view.window.clone(), (position.x, position.y), false);
            view.managed_box = (model.tiled || model.presentation != Presentation::Normal)
                .then_some(model.geometry);
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
            .is_some_and(|window| window.mapped());
        let mut changed = false;
        if !mapped {
            if was_mapped {
                self.space.unmap_elem(&view.window);
                self.desktop.unmap(view.id);
                view.configured = false;
                view.initial = None;
                view.acked = None;
                view.resize_flight = None;
                view.managed_configure = None;
                view.managed_flight = None;
                view.queued_configure = None;
                view.managed_box = None;
                view.reply_to_request = false;
                changed = true;
                toplevel.reset_initial_configure_sent();
                toplevel
                    .with_pending_state(|state| state.states.unset(xdg_toplevel::State::Resizing));
                tracing::info!(window = view.id.get(), "Window unmapped");
            } else if root == *surface && view.initial.is_none() {
                // Initial configure follows the initial bufferless commit,
                // never get_toplevel. Remap performs the handshake again.
                let output = self
                    .desktop
                    .workspace_output(view.id)
                    .and_then(|id| self.desktop.output(id));
                let model = self.desktop.get(view.id);
                let presentation = model
                    .filter(|_| output.is_some())
                    .map_or(Presentation::Normal, |w| w.presentation);
                let initial = output.and_then(|out| match presentation {
                    Presentation::Normal if self.desktop.can_move_resize(view.id) => self
                        .desktop
                        .placement(view.id, out.usable.size)
                        .map(|(_, size)| size),
                    Presentation::Normal => None,
                    Presentation::Maximized => Some(out.usable.size),
                    Presentation::Fullscreen => Some(out.geometry.size),
                });
                if let Some(size) = initial {
                    let config = ManagedConfigure {
                        size,
                        presentation,
                        tiled: false,
                    };
                    configure_managed(toplevel, config);
                    if presentation != Presentation::Normal {
                        view.managed_configure = Some(config);
                    }
                } else {
                    toplevel.with_pending_state(|state| {
                        state.size = None;
                        update_managed_flags(state, false, Presentation::Normal);
                    });
                }
                view.initial = Some(toplevel.send_configure());
                view.reply_to_request = false;
                tracing::info!(window = view.id.get(), "Initial configure sent");
            }
        } else if view.configured {
            let geometry = view.window.geometry();
            if let Some(size) =
                Size::new(geometry.size.w.max(0) as u32, geometry.size.h.max(0) as u32)
            {
                if root == *surface {
                    changed |= self.desktop.set_size_hints(view.id, size_hints(&root));
                }
                if !was_mapped {
                    let output = self
                        .desktop
                        .workspace_output(view.id)
                        .and_then(|id| self.desktop.output(id));
                    let bounds = output.map_or(size, |out| out.usable.size);
                    let (mut position, fallback) = self
                        .desktop
                        .placement(view.id, bounds)
                        .unwrap_or((Position::default(), size));
                    let new_window = self
                        .desktop
                        .get(view.id)
                        .is_some_and(|w| w.floating_geometry.is_none());
                    let floating_size = if view.managed_configure.is_some() {
                        fallback
                    } else {
                        size
                    };
                    if new_window {
                        position.x =
                            position
                                .x
                                .min(bounds.width.get().saturating_sub(floating_size.width.get())
                                    as i32);
                        position.y = position.y.min(
                            bounds
                                .height
                                .get()
                                .saturating_sub(floating_size.height.get())
                                as i32,
                        );
                        if let Some(output) = output {
                            position.x = position.x.saturating_add(output.usable.position.x);
                            position.y = position.y.saturating_add(output.usable.position.y);
                        }
                    }
                    self.desktop.map(view.id, position, size);
                    if new_window {
                        self.desktop.seed_floating_geometry(
                            view.id,
                            Geometry {
                                position,
                                size: floating_size,
                            },
                        );
                    }
                    changed = true;
                }
                let resized = view.resize_flight.filter(|(serial, _)| {
                    root == *surface && view.acked.is_some_and(|acked| acked >= *serial)
                });
                let managed_ack = root == *surface
                    && view
                        .managed_flight
                        .is_some_and(|(serial, _)| view.acked.is_some_and(|acked| acked >= serial));
                if managed_ack {
                    view.managed_flight = None;
                    changed |= view.queued_configure.is_some();
                }
                if (resized.is_some() || view.resize_flight.is_none())
                    && view.managed_flight.is_none()
                    && (root == *surface || self.desktop.can_move_resize(view.id))
                {
                    changed |= self.desktop.commit_geometry(
                        view.id,
                        size,
                        view.managed_configure.is_none(),
                    );
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
        if changed {
            self.sync_focus();
            self.repair_pointer_focus();
        }
        self.reposition_popups();
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
                && self.desktop.can_move_resize(view.id)
                && view.managed_flight.is_none()
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

impl State {
    fn request_presentation(&mut self, surface: &ToplevelSurface, fullscreen: bool, enabled: bool) {
        let Some(id) = self.window_id(surface.wl_surface()) else {
            return;
        };
        if self.desktop.interaction_window() == Some(id) {
            self.cancel_operation();
        }
        if let Err(error) = self.desktop.protocol_presentation(id, fullscreen, enabled) {
            tracing::debug!(%error, "XDG presentation preference could not be applied");
        }
        if let Some(view) = self.views.iter_mut().find(|view| view.id == id) {
            view.reply_to_request = true;
        }
        self.sync_focus();
        self.repair_pointer_focus();
        self.reposition_popups();
        self.redraw = true;
    }
}

impl View {
    pub fn send_focus_configure(&mut self) {
        if self.initial.is_none() {
            return;
        }
        let Some(top) = self.window.toplevel() else {
            return;
        };
        let force = std::mem::take(&mut self.reply_to_request);
        // Repeated geometry changes within one mode coalesce until the
        // outstanding configure is ACKed and committed. An explicit XDG
        // request or a new mode may send immediately, superseding that gate.
        let managed = self.queued_configure.filter(|next| {
            force
                || self.managed_flight.is_none_or(|(_, flight)| {
                    (next.tiled, next.presentation) != (flight.tiled, flight.presentation)
                })
        });
        if let Some(config) = managed {
            self.queued_configure = None;
            configure_managed(top, config);
        }
        let serial = if force {
            Some(top.send_configure())
        } else {
            top.send_pending_configure()
        };
        if let Some(configure) = serial.zip(managed) {
            self.managed_flight = Some(configure);
        }
    }
}

fn configure_managed(top: &ToplevelSurface, config: ManagedConfigure) {
    top.with_pending_state(|state| {
        state.size = Some(
            (
                config.size.width.get() as i32,
                config.size.height.get() as i32,
            )
                .into(),
        );
        update_managed_flags(state, config.tiled, config.presentation);
    });
}

fn update_managed_flags(
    state: &mut smithay::wayland::shell::xdg::ToplevelState,
    tiled: bool,
    presentation: Presentation,
) {
    for (flag, enabled) in [
        (
            xdg_toplevel::State::Maximized,
            presentation == Presentation::Maximized,
        ),
        (
            xdg_toplevel::State::Fullscreen,
            presentation == Presentation::Fullscreen,
        ),
        (xdg_toplevel::State::TiledLeft, tiled),
        (xdg_toplevel::State::TiledRight, tiled),
        (xdg_toplevel::State::TiledTop, tiled),
        (xdg_toplevel::State::TiledBottom, tiled),
    ] {
        if enabled {
            state.states.set(flag);
        } else {
            state.states.unset(flag);
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
                    managed_box: None,
                    managed_configure: None,
                    managed_flight: None,
                    queued_configure: None,
                    reply_to_request: false,
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
    fn parent_changed(&mut self, surface: ToplevelSurface) {
        let Some(id) = self.window_id(surface.wl_surface()) else {
            return;
        };
        let parent = surface.parent().and_then(|parent| self.window_id(&parent));
        if let Err(error) = self.desktop.set_parent(id, parent) {
            tracing::warn!(%error, "Cannot update transient parent");
        }
        self.sync_focus();
        self.repair_pointer_focus();
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
    fn maximize_request(&mut self, surface: ToplevelSurface) {
        self.request_presentation(&surface, false, true);
    }
    fn unmaximize_request(&mut self, surface: ToplevelSurface) {
        self.request_presentation(&surface, false, false);
    }
    fn fullscreen_request(
        &mut self,
        surface: ToplevelSurface,
        _output: Option<smithay::reexports::wayland_server::protocol::wl_output::WlOutput>,
    ) {
        self.request_presentation(&surface, true, true);
    }
    fn unfullscreen_request(&mut self, surface: ToplevelSurface) {
        self.request_presentation(&surface, true, false);
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
