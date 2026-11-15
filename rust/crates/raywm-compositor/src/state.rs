use smithay::{
    backend::renderer::utils::on_commit_buffer_handler,
    delegate_compositor, delegate_shm,
    reexports::wayland_server::{
        backend::{ClientData, ClientId, DisconnectReason},
        protocol::{wl_buffer::WlBuffer, wl_surface::WlSurface},
        Client, DisplayHandle,
    },
    wayland::{
        buffer::BufferHandler,
        compositor::{CompositorClientState, CompositorHandler, CompositorState},
        shm::{ShmHandler, ShmState},
    },
};

pub struct State {
    compositor: CompositorState,
    shm: ShmState,
}

impl State {
    pub fn new(display: &DisplayHandle) -> Self {
        Self {
            compositor: CompositorState::new::<Self>(display),
            shm: ShmState::new::<Self>(display, vec![]),
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
        // or renderer is needed. Surfaces are invisible: do not fake frame done.
        on_commit_buffer_handler::<Self>(surface);
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
