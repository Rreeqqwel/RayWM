//! Standard clipboard and primary selection.
//!
//! Smithay owns the protocol resources, per-seat selection, offers and the
//! data transfer fd path. This adapter adds three small policies only:
//!
//! * the data-device focus follows the existing keyboard focus (never a second
//!   focus mechanism),
//! * a `set_selection` serial must have been delivered to the requesting client
//!   since its current keyboard focus began, and
//! * a data device created by an already focused client is refreshed with the
//!   current offer immediately.
//!
//! Clipboard bytes are never copied through the compositor: the receiver's
//! `receive` fd is forwarded to the source client as `wl_data_source.send`.

use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

use smithay::{
    input::Seat,
    reexports::{
        wayland_protocols::wp::primary_selection::zv1::server::{
            zwp_primary_selection_device_manager_v1::{
                self as primary_manager, ZwpPrimarySelectionDeviceManagerV1,
            },
            zwp_primary_selection_device_v1::{self, ZwpPrimarySelectionDeviceV1},
            zwp_primary_selection_source_v1::ZwpPrimarySelectionSourceV1,
        },
        wayland_server::{
            backend::ClientId,
            protocol::{
                wl_data_device::{self, WlDataDevice},
                wl_data_device_manager::{self, WlDataDeviceManager},
                wl_data_source::WlDataSource,
                wl_surface::WlSurface,
            },
            Client, DataInit, Dispatch, DisplayHandle, Resource,
        },
    },
    utils::{Logical, Point, Serial},
    wayland::{
        compositor::{get_parent, with_states, SurfaceAttributes},
        selection::{
            data_device::{
                self, ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, DataDeviceUserData,
                DataSourceUserData, ServerDndGrabHandler,
            },
            primary_selection::{
                self, PrimaryDeviceUserData, PrimarySelectionHandler, PrimarySelectionState,
                PrimarySourceUserData,
            },
            SelectionHandler, SelectionSource, SelectionTarget,
        },
    },
};

use crate::state::State;

/// A selection serial is accepted for this long after it was delivered. Input
/// activity continually refreshes the log; the window only bounds the case of
/// a client reusing a serial after a long idle period.
const SERIAL_LIFETIME: Duration = Duration::from_secs(10);
const SERIAL_LOG_LIMIT: usize = 64;

/// The target a client may use as its current `set_selection` serial.
struct SerialLog {
    focus: Option<ClientId>,
    entries: VecDeque<(Serial, ClientId, Instant)>,
}

impl SerialLog {
    fn new() -> Self {
        Self {
            focus: None,
            entries: VecDeque::new(),
        }
    }

    /// Track a keyboard focus transition. `delivered` is true when the client
    /// actually received a `wl_keyboard.enter` with this serial.
    fn note_focus(&mut self, client: Option<ClientId>, delivered: bool, serial: Serial) {
        if self.focus != client {
            self.entries.clear();
            self.focus = client.clone();
        }
        if delivered {
            if let Some(client) = client {
                self.push(serial, client);
            }
        }
    }

    /// Track an input serial delivered to one of the focused client's objects.
    #[cfg(feature = "winit")]
    fn note(&mut self, serial: Serial, client: &ClientId) {
        if self.focus.as_ref() == Some(client) {
            self.push(serial, client.clone());
        }
    }

    fn push(&mut self, serial: Serial, client: ClientId) {
        self.prune();
        self.entries.push_back((serial, client, Instant::now()));
        while self.entries.len() > SERIAL_LOG_LIMIT {
            self.entries.pop_front();
        }
    }

    fn prune(&mut self) {
        let now = Instant::now();
        while self
            .entries
            .front()
            .is_some_and(|(_, _, when)| now.duration_since(*when) > SERIAL_LIFETIME)
        {
            self.entries.pop_front();
        }
    }

    fn permits(&mut self, serial: Serial, client: &ClientId) -> bool {
        self.prune();
        self.entries
            .iter()
            .any(|(known, owner, _)| *known == serial && owner == client)
    }
}

/// The client-provided `wl_surface` shown under the pointer during a DnD.
/// Smithay owns the grab and negotiation; this is only the render position.
pub struct DragIcon {
    pub surface: WlSurface,
    pub offset: Point<i32, Logical>,
}

pub struct SelectionState {
    pub data_device: DataDeviceState,
    pub primary: PrimarySelectionState,
    pub drag_icon: Option<DragIcon>,
    focus_client: Option<Client>,
    serials: SerialLog,
}

impl SelectionState {
    pub fn new(display: &DisplayHandle) -> Self {
        Self {
            data_device: DataDeviceState::new::<State>(display),
            primary: PrimarySelectionState::new::<State>(display),
            drag_icon: None,
            focus_client: None,
            serials: SerialLog::new(),
        }
    }

    fn focused(&self) -> Option<ClientId> {
        self.focus_client.as_ref().map(Client::id)
    }

    fn note_focus(&mut self, client: Option<&Client>, delivered: bool, serial: Serial) {
        let changed = self.focus_client.as_ref().map(Client::id) != client.map(Client::id);
        if changed {
            self.focus_client = client.cloned();
        }
        self.serials
            .note_focus(client.map(Client::id), delivered, serial);
    }

    #[cfg(feature = "winit")]
    fn note_serial(&mut self, serial: Serial, client: &ClientId) {
        self.serials.note(serial, client);
    }

    fn permits(&mut self, serial: Serial, client: &ClientId) -> bool {
        self.serials.permits(serial, client)
    }
}

impl State {
    /// Record an input serial that a focused client can later present with
    /// `set_selection` (for example the Ctrl+C key press or a pointer button).
    /// Headless mode has no seat, so it can never receive such a request.
    #[cfg(feature = "winit")]
    pub fn note_selection_serial(&mut self, serial: Serial, surface: Option<&WlSurface>) {
        let Some(surface) = surface else {
            return;
        };
        let Ok(client) = self.display.get_client(surface.id()) else {
            return;
        };
        self.selection.note_serial(serial, &client.id());
    }

    /// Set the seat keyboard focus and derive the data-device/primary focus
    /// from exactly that transition. There is no second focus mechanism.
    pub fn set_keyboard_focus(&mut self, target: Option<WlSurface>, serial: Serial) {
        let Some(keyboard) = self.seat.as_ref().and_then(|seat| seat.get_keyboard()) else {
            return;
        };
        let before = keyboard.current_focus();
        keyboard.set_focus(self, target, serial);
        let after = keyboard.current_focus();
        if before != after {
            tracing::info!(
                before = ?before.as_ref().map(|surface| surface.id()),
                after = ?after.as_ref().map(|surface| surface.id()),
                "Keyboard focus applied"
            );
        }
        let client = after
            .as_ref()
            .and_then(|surface| self.display.get_client(surface.id()).ok());
        self.selection
            .note_focus(client.as_ref(), before != after, serial);
        if let Some(seat) = self.seat.clone() {
            data_device::set_data_device_focus(&self.display, &seat, client.clone());
            primary_selection::set_primary_focus(&self.display, &seat, client);
        }
    }

    /// Inform a newly created data device of the current selection when its
    /// client already owns the keyboard focus. Without this, Smithay only
    /// offers the selection on the next focus/selection transition.
    pub fn refresh_clipboard_device(&mut self, seat: &Seat<Self>, client: &Client) {
        if self.selection.focused() == Some(client.id()) {
            data_device::set_data_device_focus(&self.display, seat, None);
            data_device::set_data_device_focus(&self.display, seat, Some(client.clone()));
        }
    }

    pub fn refresh_primary_device(&mut self, seat: &Seat<Self>, client: &Client) {
        if self.selection.focused() == Some(client.id()) {
            primary_selection::set_primary_focus(&self.display, seat, None);
            primary_selection::set_primary_focus(&self.display, seat, Some(client.clone()));
        }
    }

    /// A source object died. Force Smithay's selection broadcast to re-run its
    /// liveness check now, so a focused receiver gets a null selection instead
    /// of retaining an inert offer until the next unrelated focus change.
    pub fn refresh_selection_after_source_change(&mut self) {
        let Some(seat) = self.seat.clone() else {
            return;
        };
        let client = self.selection.focus_client.clone();
        data_device::set_data_device_focus(&self.display, &seat, None);
        data_device::set_data_device_focus(&self.display, &seat, client.clone());
        primary_selection::set_primary_focus(&self.display, &seat, None);
        primary_selection::set_primary_focus(&self.display, &seat, client);
    }

    /// A commit of the drag-icon surface (or one of its subsurfaces) can change
    /// the displayed buffer. `buffer_delta` is the client-requested icon shift.
    pub fn commit_drag_icon(&mut self, surface: &WlSurface) -> bool {
        let Some(root) = self
            .selection
            .drag_icon
            .as_ref()
            .map(|icon| icon.surface.clone())
        else {
            return false;
        };
        if !surface_belongs_to(surface, &root) {
            return false;
        }
        if *surface == root {
            let delta = with_states(surface, |states| {
                states
                    .cached_state
                    .get::<SurfaceAttributes>()
                    .current()
                    .buffer_delta
                    .take()
            });
            if let Some(delta) = delta {
                if let Some(icon) = self.selection.drag_icon.as_mut() {
                    icon.offset += delta;
                }
            }
        }
        self.redraw = true;
        true
    }

    /// Drop the icon reference when its surface or client goes away. Smithay
    /// still owns cancellation/finish for the outstanding grab.
    pub fn remove_drag_icon(&mut self, surface: &WlSurface) {
        if self
            .selection
            .drag_icon
            .as_ref()
            .is_some_and(|icon| icon.surface == *surface)
        {
            self.selection.drag_icon = None;
            self.redraw = true;
        }
    }
}

/// Bounded parent walk; popup/icon surface trees cannot outlive 64 ancestors.
fn surface_belongs_to(surface: &WlSurface, root: &WlSurface) -> bool {
    let mut current = surface.clone();
    for _ in 0..64 {
        if current == *root {
            return true;
        }
        match get_parent(&current) {
            Some(parent) => current = parent,
            None => return false,
        }
    }
    false
}

impl SelectionHandler for State {
    type SelectionUserData = ();

    fn new_selection(
        &mut self,
        ty: SelectionTarget,
        source: Option<SelectionSource>,
        seat: Seat<Self>,
    ) {
        // SeatData owns the source. Do not retain a second handle: the offer
        // side already validates liveness and cancels the previous owner.
        tracing::info!(
            seat = seat.name(),
            clipboard = ty == SelectionTarget::Clipboard,
            mime_types = ?source.as_ref().map(SelectionSource::mime_types),
            "Selection owner changed"
        );
    }
}

impl DataDeviceHandler for State {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.selection.data_device
    }
}

impl PrimarySelectionHandler for State {
    fn primary_selection_state(&self) -> &PrimarySelectionState {
        &self.selection.primary
    }
}

impl ClientDndGrabHandler for State {
    fn started(&mut self, source: Option<WlDataSource>, icon: Option<WlSurface>, seat: Seat<Self>) {
        // Smithay's DnDGrab owns negotiation, offers and target switching. The
        // compositor only keeps the icon surface and its display offset.
        self.dnd_active = true;
        self.selection.drag_icon = icon.map(|surface| DragIcon {
            surface,
            offset: Point::default(),
        });
        self.redraw = true;
        tracing::info!(
            seat = seat.name(),
            has_source = source.is_some(),
            has_icon = self.selection.drag_icon.is_some(),
            "Client drag-and-drop started"
        );
    }

    fn dropped(&mut self, target: Option<WlSurface>, validated: bool, seat: Seat<Self>) {
        // Called for a real drop and for grab cancellation/unset.
        self.dnd_active = false;
        self.selection.drag_icon = None;
        self.redraw = true;
        tracing::info!(
            seat = seat.name(),
            has_target = target.is_some(),
            validated,
            "Client drag-and-drop finished"
        );
    }
}

impl ServerDndGrabHandler for State {
    // The compositor never starts a server-side drag. No compositor-owned
    // selection or DnD source exists, so no fd can be dropped here.
}

// The manager is delegated to Smithay, but a new data device needs an explicit
// refresh when its client is already focused (see `refresh_clipboard_device`).
impl Dispatch<WlDataDeviceManager, ()> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &WlDataDeviceManager,
        request: wl_data_device_manager::Request,
        data: &(),
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        let refresh = match &request {
            wl_data_device_manager::Request::GetDataDevice { seat, .. } => Some(seat.clone()),
            _ => None,
        };
        <DataDeviceState as Dispatch<WlDataDeviceManager, (), Self>>::request(
            state, client, resource, request, data, dh, init,
        );
        if let Some(seat) = refresh.and_then(|seat| Seat::<Self>::from_resource(&seat)) {
            state.refresh_clipboard_device(&seat, client);
        }
    }
}

// Serial policy is enforced here, then the request runs through Smithay's
// implementation. Smithay independently requires the client's data device to
// belong to a real seat and its client to own the keyboard focus.
impl Dispatch<WlDataDevice, DataDeviceUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &WlDataDevice,
        request: wl_data_device::Request,
        data: &DataDeviceUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        if let wl_data_device::Request::SetSelection { serial, .. } = &request {
            let serial = Serial::from(*serial);
            if !state.selection.permits(serial, &client.id()) {
                tracing::warn!(
                    serial = u32::from(serial),
                    "Denying clipboard selection without a matching recent input serial"
                );
                return;
            }
        }
        <DataDeviceState as Dispatch<WlDataDevice, DataDeviceUserData, Self>>::request(
            state, client, resource, request, data, dh, init,
        );
    }
}

impl Dispatch<ZwpPrimarySelectionDeviceManagerV1, ()> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &ZwpPrimarySelectionDeviceManagerV1,
        request: primary_manager::Request,
        data: &(),
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        let refresh = match &request {
            primary_manager::Request::GetDevice { seat, .. } => Some(seat.clone()),
            _ => None,
        };
        <PrimarySelectionState as Dispatch<ZwpPrimarySelectionDeviceManagerV1, (), Self>>::request(
            state, client, resource, request, data, dh, init,
        );
        if let Some(seat) = refresh.and_then(|seat| Seat::<Self>::from_resource(&seat)) {
            state.refresh_primary_device(&seat, client);
        }
    }
}

impl Dispatch<ZwpPrimarySelectionDeviceV1, PrimaryDeviceUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &ZwpPrimarySelectionDeviceV1,
        request: zwp_primary_selection_device_v1::Request,
        data: &PrimaryDeviceUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        if let zwp_primary_selection_device_v1::Request::SetSelection { serial, .. } = &request {
            let serial = Serial::from(*serial);
            if !state.selection.permits(serial, &client.id()) {
                tracing::warn!(
                    serial = u32::from(serial),
                    "Denying primary selection without a matching recent input serial"
                );
                return;
            }
        }
        <PrimarySelectionState as Dispatch<
            ZwpPrimarySelectionDeviceV1,
            PrimaryDeviceUserData,
            Self,
        >>::request(state, client, resource, request, data, dh, init);
    }
}

// Manager/source dispatch is pure Smithay delegation; only the device objects
// above add a policy layer.
smithay::reexports::wayland_server::delegate_global_dispatch!(
    State: [WlDataDeviceManager: ()] => DataDeviceState
);
impl Dispatch<WlDataSource, DataSourceUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &WlDataSource,
        request: <WlDataSource as Resource>::Request,
        data: &DataSourceUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        <DataDeviceState as Dispatch<WlDataSource, DataSourceUserData, Self>>::request(
            state, client, resource, request, data, dh, init,
        );
    }

    fn destroyed(
        state: &mut Self,
        client: ClientId,
        resource: &WlDataSource,
        data: &DataSourceUserData,
    ) {
        <DataDeviceState as Dispatch<WlDataSource, DataSourceUserData, Self>>::destroyed(
            state, client, resource, data,
        );
        state.refresh_selection_after_source_change();
    }
}
smithay::reexports::wayland_server::delegate_global_dispatch!(
    State: [ZwpPrimarySelectionDeviceManagerV1: smithay::wayland::selection::primary_selection::PrimaryDeviceManagerGlobalData]
        => PrimarySelectionState
);
impl Dispatch<ZwpPrimarySelectionSourceV1, PrimarySourceUserData> for State {
    fn request(
        state: &mut Self,
        client: &Client,
        resource: &ZwpPrimarySelectionSourceV1,
        request: <ZwpPrimarySelectionSourceV1 as Resource>::Request,
        data: &PrimarySourceUserData,
        dh: &DisplayHandle,
        init: &mut DataInit<'_, Self>,
    ) {
        <PrimarySelectionState as Dispatch<
            ZwpPrimarySelectionSourceV1,
            PrimarySourceUserData,
            Self,
        >>::request(state, client, resource, request, data, dh, init);
    }

    fn destroyed(
        state: &mut Self,
        client: ClientId,
        resource: &ZwpPrimarySelectionSourceV1,
        data: &PrimarySourceUserData,
    ) {
        <PrimarySelectionState as Dispatch<
            ZwpPrimarySelectionSourceV1,
            PrimarySourceUserData,
            Self,
        >>::destroyed(state, client, resource, data);
        state.refresh_selection_after_source_change();
    }
}
