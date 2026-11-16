use raywm_core::windows::Desktop;
use smithay::{
    backend::renderer::utils::on_commit_buffer_handler,
    delegate_compositor, delegate_seat, delegate_shm,
    desktop::{PopupGrab, PopupManager, Space, Window},
    input::{Seat, SeatHandler, SeatState},
    output::Output,
    reexports::wayland_server::{
        backend::{ClientData, ClientId, DisconnectReason},
        protocol::{wl_buffer::WlBuffer, wl_surface::WlSurface},
        Client, DisplayHandle,
    },
    wayland::{
        buffer::BufferHandler,
        compositor::{CompositorClientState, CompositorHandler, CompositorState},
        output::OutputManagerState,
        shell::xdg::XdgShellState,
        shm::{ShmHandler, ShmState},
    },
};

use crate::selection::SelectionState;
use crate::shell::View;

pub struct State {
    pub display: DisplayHandle,
    pub selection: SelectionState,
    compositor: CompositorState,
    shm: ShmState,
    pub xdg: XdgShellState,
    pub space: Space<Window>,
    pub desktop: Desktop,
    pub views: Vec<View>,
    pub redraw: bool,
    pub seat_state: SeatState<Self>,
    pub seat: Option<Seat<Self>>,
    pub output: Option<Output>,
    pub output_manager: Option<OutputManagerState>,
    pub host_focused: bool,
    pub pressed_buttons: Vec<u32>,
    pub pointer_blocked: bool,
    pub dnd_active: bool,
    pub popups: PopupManager,
    pub popup_entries: Vec<crate::popups::PopupEntry>,
    pub popup_grab: Option<PopupGrab<Self>>,
    pub popup_root: Option<raywm_core::windows::WindowId>,
    pub pointer_grant: Option<(smithay::utils::Serial, WlSurface, std::time::Instant)>,
    pub key_grant: Option<(smithay::utils::Serial, WlSurface, std::time::Instant)>,
}

impl State {
    pub fn new(display: &DisplayHandle) -> Self {
        Self {
            display: display.clone(),
            selection: SelectionState::new(display),
            compositor: CompositorState::new::<Self>(display),
            shm: ShmState::new::<Self>(display, vec![]),
            xdg: XdgShellState::new_with_capabilities::<Self>(display, std::iter::empty::<smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::WmCapabilities>()),
            space: Space::default(),
            desktop: Desktop::default(),
            views: Vec::new(),
            redraw: true,
            seat_state: SeatState::new(),
            seat: None,
            output: None,
            output_manager: None,
            host_focused: false,
            pressed_buttons: Vec::new(),
            pointer_blocked: false,
            dnd_active: false,
            popups: PopupManager::default(),
            popup_entries: Vec::new(),
            popup_grab: None,
            popup_root: None,
            pointer_grant: None,
            key_grant: None,
        }
    }
}

/// Every client enters through the single listener with this data attached.
#[derive(Default)]
pub struct ClientState {
    compositor: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, client_id: ClientId) {
        tracing::info!(?client_id, "Wayland client connected");
    }

    fn disconnected(&self, client_id: ClientId, reason: DisconnectReason) {
        tracing::info!(?client_id, ?reason, "Wayland client disconnected");
    }
}

impl CompositorHandler for State {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        // An internal type invariant, not a fallible runtime operation: the only
        // insert_client call always installs ClientState before any dispatch.
        #[allow(clippy::expect_used)]
        &client
            .get_data::<ClientState>()
            .expect("all clients are inserted with ClientState")
            .compositor
    }

    fn commit(&mut self, surface: &WlSurface) {
        // Smithay applies synchronized subsurface transactions, owns current
        // buffers and releases them on replacement/destruction. No pixel read
        // or renderer is needed here. The graphics backend alone sends frame
        // callbacks, after a successful render/submit of mapped surfaces.
        on_commit_buffer_handler::<Self>(surface);
        self.commit_popup(surface);
        self.commit_window(surface);
        self.commit_drag_icon(surface);
    }

    fn new_surface(&mut self, surface: &WlSurface) {
        smithay::wayland::compositor::add_pre_commit_hook::<Self, _>(
            surface,
            |state, _, surface| {
                state.validate_window_commit(surface);
            },
        );
    }

    fn destroyed(&mut self, surface: &WlSurface) {
        self.remove_drag_icon(surface);
        self.remove_popup(surface);
        self.remove_window(surface);
    }
}

impl BufferHandler for State {
    fn buffer_destroyed(&mut self, _buffer: &WlBuffer) {}
}

impl ShmHandler for State {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}

delegate_compositor!(State);
delegate_shm!(State);

impl SeatHandler for State {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }
    fn cursor_image(&mut self, _: &Seat<Self>, _: smithay::input::pointer::CursorImageStatus) {}
}

delegate_seat!(State);
