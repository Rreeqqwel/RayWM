//! Real socket/protocol tests. Each subprocess has a private runtime directory,
//! a scrubbed environment, bounded waits and a kill/reap guard on failure.

use std::{
    error::Error,
    fs::{self, File},
    io::{Read, Write},
    os::{
        fd::AsFd,
        unix::{fs::PermissionsExt, net::UnixStream},
    },
    path::PathBuf,
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};

use rustix::{
    event::{poll, PollFd, PollFlags, Timespec},
    process::{kill_process, Pid, Signal},
};
use tempfile::TempDir;
use wayland_client::protocol::wl_data_device_manager::DndAction;
use wayland_client::{
    delegate_noop,
    protocol::{
        wl_buffer, wl_callback, wl_compositor, wl_data_device, wl_data_device_manager,
        wl_data_offer, wl_data_source, wl_keyboard, wl_output, wl_pointer, wl_registry, wl_seat,
        wl_shm, wl_shm_pool, wl_subcompositor, wl_subsurface, wl_surface,
    },
    Connection, Dispatch, EventQueue, QueueHandle, WEnum,
};
use wayland_protocols::{
    wp::primary_selection::zv1::client::{
        zwp_primary_selection_device_v1, zwp_primary_selection_offer_v1,
        zwp_primary_selection_source_v1,
    },
    xdg::shell::client::{xdg_surface, xdg_toplevel, xdg_wm_base},
};

#[cfg(feature = "winit")]
mod dnd;
mod floating;
mod selection;

type Result<T> = std::result::Result<T, Box<dyn Error>>;
const WAIT: Duration = Duration::from_secs(5);

struct Server {
    child: Child,
    dir: TempDir,
    socket: PathBuf,
}

impl Server {
    fn start(name: Option<&str>) -> Result<Self> {
        let dir = tempfile::tempdir()?;
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700))?;
        let log = File::create(dir.path().join("server.log"))?;
        let mut command = Command::new(env!("CARGO_BIN_EXE_raywm-smithay"));
        command
            .env_clear()
            .env("XDG_RUNTIME_DIR", dir.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(log);
        if let Some(name) = name {
            command.args(["--socket", name]);
        }
        let child = command.spawn()?;
        let socket = dir.path().join(name.unwrap_or("wayland-1"));
        let mut server = Self { child, dir, socket };
        let deadline = Instant::now() + WAIT;
        while !server.socket.exists() {
            if server.child.try_wait()?.is_some() || Instant::now() >= deadline {
                return Err(format!("startup failed: {}", server.log()?).into());
            }
            thread::sleep(Duration::from_millis(10));
        }
        Ok(server)
    }

    fn log(&self) -> Result<String> {
        Ok(fs::read_to_string(self.dir.path().join("server.log"))?)
    }

    fn connect(&self) -> Result<(Connection, EventQueue<Probe>, Probe)> {
        let connection = Connection::from_socket(UnixStream::connect(&self.socket)?)?;
        let mut queue = connection.new_event_queue();
        connection.display().get_registry(&queue.handle(), ());
        let mut probe = Probe::default();
        roundtrip(&connection, &mut queue, &mut probe)?;
        Ok((connection, queue, probe))
    }

    fn stop(&mut self, signal: Signal) -> Result<()> {
        let pid = Pid::from_raw(self.child.id() as i32).ok_or("invalid child PID")?;
        kill_process(pid, signal)?;
        let status = wait(&mut self.child)?;
        assert!(status.success(), "{}\n{}", status, self.log()?);
        assert!(!self.socket.exists(), "socket survived shutdown");
        assert!(!self.socket.with_extension("lock").exists());
        assert!(self.log()?.contains("Headless Wayland server stopped"));
        Ok(())
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn wait(child: &mut Child) -> Result<ExitStatus> {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            child.kill()?;
            let _ = child.wait();
            return Err("subprocess did not finish within five seconds".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[derive(Default)]
struct Probe {
    globals: Vec<(u32, String, u32)>,
    synced: bool,
    frames: usize,
    #[cfg(feature = "winit")]
    barriers: Vec<u32>,
    hidden_frames: usize,
    released: usize,
    formats: Vec<wl_shm::Format>,
    configures: Vec<u32>,
    sizes: Vec<(i32, i32)>,
    keyboard: Option<wl_keyboard::WlKeyboard>,
    pointer: Option<wl_pointer::WlPointer>,
    keys: Vec<(u32, WEnum<wl_keyboard::KeyState>)>,
    buttons: Vec<(u32, WEnum<wl_pointer::ButtonState>)>,
    motions: usize,
    keyboard_enters: usize,
    keyboard_leaves: usize,
    pointer_leaves: usize,
    output_enters: usize,
    output_leaves: usize,
    modes: Vec<(i32, i32)>,
    wm_capabilities: Option<Vec<u8>>,
    keyboard_focus: Option<wl_surface::WlSurface>,
    pointer_focus: Option<wl_surface::WlSurface>,
    pointer_position: Option<(f64, f64)>,
    input_serials: Vec<(u32, WEnum<wl_pointer::ButtonState>)>,
    key_serial: Option<u32>,
    activated: bool,
    resizing: bool,
    surface_configures: Vec<(xdg_surface::XdgSurface, u32)>,
    popup_geometry: Vec<(
        wayland_protocols::xdg::shell::client::xdg_popup::XdgPopup,
        (i32, i32, i32, i32),
    )>,
    popup_done: Vec<wayland_protocols::xdg::shell::client::xdg_popup::XdgPopup>,
    repositioned: Vec<u32>,
    keyboard_enter_serial: Option<u32>,
    clipboard_selection: Vec<Option<wl_data_offer::WlDataOffer>>,
    offer_mime_types: Vec<(wl_data_offer::WlDataOffer, String)>,
    source_sends: Vec<(String, usize)>,
    source_send_errors: usize,
    source_cancelled: usize,
    primary_selection: Vec<Option<zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1>>,
    primary_offer_mime_types: Vec<(
        zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1,
        String,
    )>,
    primary_sends: Vec<(String, usize)>,
    primary_send_errors: usize,
    primary_cancelled: usize,
    dnd_enters: Vec<(
        u32,
        wl_surface::WlSurface,
        Option<wl_data_offer::WlDataOffer>,
        f64,
        f64,
    )>,
    dnd_motions: Vec<(f64, f64)>,
    dnd_leaves: usize,
    dnd_drops: usize,
    offer_source_actions: Vec<(wl_data_offer::WlDataOffer, WEnum<DndAction>)>,
    offer_actions: Vec<(wl_data_offer::WlDataOffer, WEnum<DndAction>)>,
    source_targets: Vec<Option<String>>,
    source_actions: Vec<WEnum<DndAction>>,
    source_drop_performed: usize,
    source_finished: usize,
}

impl Probe {
    fn global(&self, interface: &str) -> Result<(u32, u32)> {
        self.globals
            .iter()
            .find(|(_, name, _)| name == interface)
            .map(|(id, _, version)| (*id, *version))
            .ok_or_else(|| format!("missing global {interface}").into())
    }
}

#[derive(Clone, Copy)]
enum Callback {
    Sync,
    Frame,
    HiddenFrame,
    #[cfg(feature = "winit")]
    Barrier(u32),
}

// Unlike EventQueue::roundtrip, this helper has a deadline even if the server
// accepts a connection but never dispatches or flushes any protocol requests.
fn roundtrip(
    connection: &Connection,
    queue: &mut EventQueue<Probe>,
    probe: &mut Probe,
) -> Result<()> {
    probe.synced = false;
    connection.display().sync(&queue.handle(), Callback::Sync);
    let deadline = Instant::now() + WAIT;
    while !probe.synced {
        queue.dispatch_pending(probe)?;
        if probe.synced {
            break;
        }
        connection.flush()?;
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err("Wayland roundtrip timed out".into());
        }
        if let Some(guard) = queue.prepare_read() {
            let timeout = Timespec::try_from(remaining)?;
            let mut fds = [PollFd::new(connection, PollFlags::IN)];
            if poll(&mut fds, Some(&timeout))? == 0 {
                return Err("Wayland socket read timed out".into());
            }
            guard.read()?;
        }
    }
    Ok(())
}

impl Dispatch<wl_registry::WlRegistry, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global {
            name,
            interface,
            version,
        } = event
        {
            state.globals.push((name, interface, version));
        }
    }
}

impl Dispatch<wl_callback::WlCallback, Callback> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_callback::WlCallback,
        _: wl_callback::Event,
        kind: &Callback,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match kind {
            Callback::Sync => state.synced = true,
            Callback::Frame => state.frames += 1,
            Callback::HiddenFrame => state.hidden_frames += 1,
            #[cfg(feature = "winit")]
            Callback::Barrier(token) => state.barriers.push(*token),
        }
    }
}

impl Dispatch<wl_shm::WlShm, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_shm::WlShm,
        event: wl_shm::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_shm::Event::Format {
            format: WEnum::Value(format),
        } = event
        {
            state.formats.push(format);
        }
    }
}

impl Dispatch<wl_buffer::WlBuffer, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_buffer::WlBuffer,
        _: wl_buffer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        state.released += 1;
    }
}

delegate_noop!(Probe: ignore wl_compositor::WlCompositor);
delegate_noop!(Probe: ignore wl_subcompositor::WlSubcompositor);
delegate_noop!(Probe: ignore wl_subsurface::WlSubsurface);
delegate_noop!(Probe: ignore wl_shm_pool::WlShmPool);

impl Dispatch<wl_surface::WlSurface, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_surface::WlSurface,
        event: wl_surface::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_surface::Event::Enter { .. } => state.output_enters += 1,
            wl_surface::Event::Leave { .. } => state.output_leaves += 1,
            _ => {}
        }
    }
}

impl Dispatch<wl_seat::WlSeat, ()> for Probe {
    fn event(
        state: &mut Self,
        seat: &wl_seat::WlSeat,
        event: wl_seat::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        if let wl_seat::Event::Capabilities {
            capabilities: WEnum::Value(capabilities),
        } = event
        {
            if capabilities.contains(wl_seat::Capability::Keyboard) && state.keyboard.is_none() {
                state.keyboard = Some(seat.get_keyboard(qh, ()));
            }
            if capabilities.contains(wl_seat::Capability::Pointer) && state.pointer.is_none() {
                state.pointer = Some(seat.get_pointer(qh, ()));
            }
        }
    }
}

impl Dispatch<wl_keyboard::WlKeyboard, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_keyboard::WlKeyboard,
        event: wl_keyboard::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_keyboard::Event::Key {
                serial,
                key,
                state: key_state,
                ..
            } => {
                state.keys.push((key, key_state));
                if key_state == WEnum::Value(wl_keyboard::KeyState::Pressed) {
                    state.key_serial = Some(serial);
                }
            }
            wl_keyboard::Event::Enter {
                serial, surface, ..
            } => {
                state.keyboard_enters += 1;
                state.keyboard_enter_serial = Some(serial);
                state.keyboard_focus = Some(surface);
            }
            wl_keyboard::Event::Leave { .. } => {
                state.keyboard_leaves += 1;
                state.keyboard_focus = None;
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_pointer::WlPointer, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_pointer::WlPointer,
        event: wl_pointer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_pointer::Event::Motion {
                surface_x,
                surface_y,
                ..
            } => {
                state.motions += 1;
                state.pointer_position = Some((surface_x, surface_y));
            }
            wl_pointer::Event::Button {
                serial,
                button,
                state: button_state,
                ..
            } => {
                state.buttons.push((button, button_state));
                state.input_serials.push((serial, button_state));
            }
            wl_pointer::Event::Enter {
                surface,
                surface_x,
                surface_y,
                ..
            } => {
                state.pointer_focus = Some(surface);
                state.pointer_position = Some((surface_x, surface_y));
            }
            wl_pointer::Event::Leave { .. } => {
                state.pointer_leaves += 1;
                state.pointer_focus = None;
            }
            _ => {}
        }
    }
}

impl Dispatch<wl_output::WlOutput, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_output::Event::Mode { width, height, .. } = event {
            state.modes.push((width, height));
        }
    }
}

impl Dispatch<xdg_wm_base::XdgWmBase, ()> for Probe {
    fn event(
        _: &mut Self,
        shell: &xdg_wm_base::XdgWmBase,
        event: xdg_wm_base::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let xdg_wm_base::Event::Ping { serial } = event {
            shell.pong(serial);
        }
    }
}

impl Dispatch<xdg_surface::XdgSurface, ()> for Probe {
    fn event(
        state: &mut Self,
        surface: &xdg_surface::XdgSurface,
        event: xdg_surface::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let xdg_surface::Event::Configure { serial } = event {
            state.configures.push(serial);
            state.surface_configures.push((surface.clone(), serial));
        }
    }
}

impl Dispatch<xdg_toplevel::XdgToplevel, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &xdg_toplevel::XdgToplevel,
        event: xdg_toplevel::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            xdg_toplevel::Event::Configure {
                width,
                height,
                states,
            } => {
                state.sizes.push((width, height));
                let states = states
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|bytes| u32::from_ne_bytes(*bytes))
                    .collect::<Vec<_>>();
                state.activated = states.contains(&(xdg_toplevel::State::Activated as u32));
                state.resizing = states.contains(&(xdg_toplevel::State::Resizing as u32));
            }
            xdg_toplevel::Event::WmCapabilities { capabilities } => {
                state.wm_capabilities = Some(capabilities)
            }
            _ => {}
        }
    }
}

struct ClientWindow {
    surface: wl_surface::WlSurface,
    xdg: xdg_surface::XdgSurface,
    top: xdg_toplevel::XdgToplevel,
    buffer: wl_buffer::WlBuffer,
}

fn create_window(
    connection: &Connection,
    queue: &EventQueue<Probe>,
    probe: &Probe,
) -> Result<ClientWindow> {
    let qh = queue.handle();
    let registry = connection.display().get_registry(&qh, ());
    let (id, version) = probe.global("wl_compositor")?;
    let compositor: wl_compositor::WlCompositor = registry.bind(id, version.min(6), &qh, ());
    let (id, version) = probe.global("xdg_wm_base")?;
    let shell: xdg_wm_base::XdgWmBase = registry.bind(id, version.min(6), &qh, ());
    let surface = compositor.create_surface(&qh, ());
    let xdg = shell.get_xdg_surface(&surface, &qh, ());
    let top = xdg.get_toplevel(&qh, ());
    top.set_title("RayWM protocol probe".into());
    let (id, _) = probe.global("wl_shm")?;
    let shm: wl_shm::WlShm = registry.bind(id, 1, &qh, ());
    let mut file = tempfile::tempfile()?;
    file.write_all(&[0xff; 16])?;
    let pool = shm.create_pool(file.as_fd(), 16, &qh, ());
    let buffer = pool.create_buffer(0, 2, 2, 8, wl_shm::Format::Argb8888, &qh, ());
    pool.destroy();
    Ok(ClientWindow {
        surface,
        xdg,
        top,
        buffer,
    })
}

#[test]
fn globals_buffers_subsurfaces_disconnect_and_sigterm() -> Result<()> {
    let mut server = Server::start(Some("raywm-test"))?;
    let (connection, mut queue, mut probe) = server.connect()?;
    let qh = queue.handle();
    let mut interfaces = probe
        .globals
        .iter()
        .map(|(_, name, _)| name.as_str())
        .collect::<Vec<_>>();
    interfaces.sort_unstable();
    assert_eq!(
        interfaces,
        [
            "wl_compositor",
            "wl_data_device_manager",
            "wl_shm",
            "wl_subcompositor",
            "xdg_wm_base",
            "zwp_primary_selection_device_manager_v1",
        ],
        "only implemented protocols are advertised"
    );
    assert_eq!(
        probe.global("wl_data_device_manager")?.1,
        3,
        "standard clipboard advertises the v3 data-device contract"
    );
    assert_eq!(
        probe.global("zwp_primary_selection_device_manager_v1")?.1,
        1
    );
    let registry = connection.display().get_registry(&qh, ());
    let (id, version) = probe.global("wl_compositor")?;
    let compositor: wl_compositor::WlCompositor = registry.bind(id, version.min(6), &qh, ());
    let (id, _) = probe.global("wl_subcompositor")?;
    let subs: wl_subcompositor::WlSubcompositor = registry.bind(id, 1, &qh, ());
    let (id, _) = probe.global("wl_shm")?;
    let shm: wl_shm::WlShm = registry.bind(id, 1, &qh, ());
    let mut file = tempfile::tempfile()?;
    file.write_all(&[0xff; 16])?;
    let pool = shm.create_pool(file.as_fd(), 16, &qh, ());
    let buffer = pool.create_buffer(0, 2, 2, 8, wl_shm::Format::Argb8888, &qh, ());
    pool.destroy();
    let parent = compositor.create_surface(&qh, ());
    let surface = compositor.create_surface(&qh, ());
    let subsurface = subs.get_subsurface(&surface, &parent, &qh, ());
    surface.frame(&qh, Callback::Frame);
    surface.attach(Some(&buffer), 0, 0);
    surface.damage_buffer(0, 0, 2, 2);
    surface.commit();
    parent.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(probe.formats.contains(&wl_shm::Format::Argb8888));
    assert!(probe.formats.contains(&wl_shm::Format::Xrgb8888));
    assert_eq!(probe.released, 0, "current buffer must remain owned");
    assert_eq!(probe.frames, 0, "invisible surfaces get no fake frame done");

    surface.attach(None, 0, 0);
    surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert_eq!(probe.released, 0, "sync child waits for parent commit");
    parent.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert_eq!(
        probe.released, 1,
        "detach releases buffer after parent commit"
    );

    // Destroy a surface with a current buffer and a pending frame callback.
    surface.attach(Some(&buffer), 0, 0);
    surface.commit();
    parent.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    subsurface.destroy();
    surface.destroy();
    parent.destroy();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert_eq!(probe.released, 2, "destroy releases the current buffer");
    assert_eq!(probe.frames, 0);
    buffer.destroy();

    // Abrupt disconnects and reconnects must not affect the original client.
    for _ in 0..8 {
        let (other, mut events, mut state) = server.connect()?;
        let qh = events.handle();
        let registry = other.display().get_registry(&qh, ());
        let (id, version) = state.global("wl_compositor")?;
        let compositor: wl_compositor::WlCompositor = registry.bind(id, version.min(6), &qh, ());
        let (id, _) = state.global("wl_shm")?;
        let shm: wl_shm::WlShm = registry.bind(id, 1, &qh, ());
        let pool = shm.create_pool(file.as_fd(), 16, &qh, ());
        let buffer = pool.create_buffer(0, 2, 2, 8, wl_shm::Format::Argb8888, &qh, ());
        let surface = compositor.create_surface(&qh, ());
        surface.attach(Some(&buffer), 0, 0);
        surface.frame(&qh, Callback::Frame);
        surface.commit();
        roundtrip(&other, &mut events, &mut state)?;
        // Drop the connection with surface, pool, buffer and callback alive.
    }
    roundtrip(&connection, &mut queue, &mut probe)?;
    server.stop(Signal::TERM)?; // original connection still alive at shutdown
    Ok(())
}

#[test]
fn malformed_client_is_isolated_and_sigint_cleans_auto_socket() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut bad = UnixStream::connect(&server.socket)?;
    bad.set_read_timeout(Some(WAIT))?;
    bad.write_all(&1_u32.to_ne_bytes())?;
    bad.write_all(&((8_u32 << 16) | 0xffff).to_ne_bytes())?; // unknown wl_display opcode
    let mut reply = Vec::new();
    bad.read_to_end(&mut reply)?;
    let (connection, mut queue, mut probe) = server.connect()?;
    roundtrip(&connection, &mut queue, &mut probe)?;
    server.stop(Signal::INT)?;
    Ok(())
}

#[test]
fn bad_startup_and_socket_collision_fail_without_removing_live_socket() -> Result<()> {
    let mut server = Server::start(Some("occupied"))?;
    for args in [
        vec!["--socket", "../escape"],
        vec!["--socket"],
        vec!["--unknown"],
        vec!["--socket", "occupied"],
        vec!["--backend"],
        vec!["--backend", "invalid"],
        vec!["--backend", "headless", "--backend", "winit"],
        vec!["--backend", "winit"], // scrubbed environment has no parent display
    ] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_raywm-smithay"))
            .env_clear()
            .env("XDG_RUNTIME_DIR", server.dir.path())
            .args(args)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        assert!(!wait(&mut child)?.success());
        assert!(
            !server.dir.path().join("wayland-1").exists(),
            "startup failure left a socket"
        );
    }
    let mut child = Command::new(env!("CARGO_BIN_EXE_raywm-smithay"))
        .env_clear()
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    assert!(!wait(&mut child)?.success());

    let public = server.dir.path().join("public");
    fs::create_dir(&public)?;
    fs::set_permissions(&public, fs::Permissions::from_mode(0o755))?;
    let symlink = server.dir.path().join("runtime-link");
    std::os::unix::fs::symlink(server.dir.path(), &symlink)?;
    for directory in [PathBuf::from("relative"), public, symlink] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_raywm-smithay"))
            .env_clear()
            .env("XDG_RUNTIME_DIR", directory)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;
        assert!(!wait(&mut child)?.success());
    }
    let (connection, mut queue, mut probe) = server.connect()?;
    roundtrip(&connection, &mut queue, &mut probe)?;
    server.stop(Signal::TERM)?;
    Ok(())
}

#[test]
fn xdg_initial_ack_map_unmap_remap_and_role_destruction() -> Result<()> {
    let mut server = Server::start(Some("xdg-lifecycle"))?;
    let (connection, mut queue, mut probe) = server.connect()?;
    let window = create_window(&connection, &queue, &probe)?;
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(
        probe.configures.is_empty(),
        "get_toplevel must not map or configure before initial commit"
    );
    assert!(!server.log()?.contains("Window mapped"));
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    let initial = *probe.configures.last().ok_or("missing initial configure")?;
    assert_eq!(
        probe.wm_capabilities,
        Some(Vec::new()),
        "do not advertise unsupported WM capabilities"
    );
    window.xdg.ack_configure(initial);
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(
        !server.log()?.contains("Window mapped"),
        "ACK without a buffer does not map"
    );
    window.surface.attach(Some(&window.buffer), 0, 0);
    window.surface.frame(&queue.handle(), Callback::Frame);
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(server.log()?.contains("Window mapped"));
    assert_eq!(
        probe.frames, 0,
        "headless mode does not fabricate presentation"
    );
    window.surface.attach(None, 0, 0);
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(server.log()?.contains("Window unmapped"));
    assert_eq!(probe.released, 1);
    let before = probe.configures.len();
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(
        probe.configures.len() > before,
        "remap needs a new configure"
    );
    let remap = *probe.configures.last().ok_or("missing remap configure")?;
    assert_ne!(initial, remap);
    window.xdg.ack_configure(remap);
    window.surface.attach(Some(&window.buffer), 0, 0);
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert_eq!(server.log()?.matches("Window mapped").count(), 2);
    window.surface.attach(None, 0, 0);
    window.surface.commit();
    window.top.destroy();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(server.log()?.contains("Window destroyed"));
    let top = window.xdg.get_toplevel(&queue.handle(), ());
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    window.xdg.ack_configure(
        *probe
            .configures
            .last()
            .ok_or("missing recreated role configure")?,
    );
    window.surface.attach(Some(&window.buffer), 0, 0);
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    top.destroy();
    window.xdg.destroy();
    window.surface.destroy();
    window.buffer.destroy();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert_eq!(server.log()?.matches("Window destroyed").count(), 2);
    server.stop(Signal::TERM)?;
    Ok(())
}

#[test]
fn xdg_unconfigured_buffer_invalid_ack_and_disconnect_are_isolated() -> Result<()> {
    let mut server = Server::start(Some("xdg-errors"))?;
    for mode in 0..5 {
        let (connection, mut queue, mut probe) = server.connect()?;
        let window = create_window(&connection, &queue, &probe)?;
        if mode != 0 {
            window.surface.commit();
            roundtrip(&connection, &mut queue, &mut probe)?;
        }
        if mode == 2 {
            window.xdg.ack_configure(u32::MAX);
        } else {
            if mode >= 3 {
                window
                    .xdg
                    .ack_configure(*probe.configures.last().ok_or("configure missing")?);
            }
            window.surface.attach(Some(&window.buffer), 0, 0);
            window.surface.commit();
            if mode == 4 {
                roundtrip(&connection, &mut queue, &mut probe)?;
                window.surface.attach(None, 0, 0);
                window.surface.commit();
                window.surface.commit();
                roundtrip(&connection, &mut queue, &mut probe)?;
                // The original ACK must not authorize a remap buffer.
                window.surface.attach(Some(&window.buffer), 0, 0);
                window.surface.commit();
            }
        }
        let result = roundtrip(&connection, &mut queue, &mut probe);
        if mode == 3 {
            result?;
        } else {
            assert!(
                result.is_err(),
                "unconfigured buffer or invalid ACK must fail"
            );
        }
        // mode 3 drops a mapped client with live resources and no destroy requests.
    }
    let (connection, mut queue, mut probe) = server.connect()?;
    roundtrip(&connection, &mut queue, &mut probe)?;
    server.stop(Signal::TERM)?;
    Ok(())
}

fn pump_until(
    connection: &Connection,
    queue: &mut EventQueue<Probe>,
    probe: &mut Probe,
    predicate: impl Fn(&Probe) -> bool,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(15);
    while !predicate(probe) {
        if Instant::now() >= deadline {
            return Err("graphics probe observation timed out".into());
        }
        roundtrip(connection, queue, probe)?;
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

fn quadrants(
    connection: &Connection,
    queue: &EventQueue<Probe>,
    probe: &Probe,
    width: i32,
    height: i32,
) -> Result<wl_buffer::WlBuffer> {
    assert!(width > 0 && height > 0 && width <= 4096 && height <= 4096);
    let registry = connection.display().get_registry(&queue.handle(), ());
    let (id, _) = probe.global("wl_shm")?;
    let shm: wl_shm::WlShm = registry.bind(id, 1, &queue.handle(), ());
    let mut pixels = Vec::with_capacity((width * height * 4) as usize);
    for y in 0..height {
        for x in 0..width {
            let color: u32 = match (x < width / 2, y < height / 2) {
                (true, true) => 0xffff0000,
                (false, true) => 0xff00ff00,
                (true, false) => 0xff0000ff,
                (false, false) => 0xffffffff,
            };
            pixels.extend_from_slice(&color.to_ne_bytes());
        }
    }
    let mut file = tempfile::tempfile()?;
    file.write_all(&pixels)?;
    let pool = shm.create_pool(file.as_fd(), pixels.len() as i32, &queue.handle(), ());
    let buffer = pool.create_buffer(
        0,
        width,
        height,
        width * 4,
        wl_shm::Format::Argb8888,
        &queue.handle(),
        (),
    );
    pool.destroy();
    Ok(buffer)
}

#[test]
#[ignore = "requires rust/tests/nested-smoke.py private graphical parent"]
fn nested_graphics_pixels_input_resize_and_unmap() -> Result<()> {
    // Explicit test socket/control paths, never the ambient WAYLAND_DISPLAY.
    let socket = std::env::var_os("RAYWM_SMOKE_SOCKET").ok_or("run nested-smoke.py")?;
    let control =
        PathBuf::from(std::env::var_os("RAYWM_SMOKE_CONTROL").ok_or("run nested-smoke.py")?);
    let connection = Connection::from_socket(UnixStream::connect(socket)?)?;
    let mut queue = connection.new_event_queue();
    let registry = connection.display().get_registry(&queue.handle(), ());
    let mut probe = Probe::default();
    roundtrip(&connection, &mut queue, &mut probe)?;
    let (id, version) = probe.global("wl_seat")?;
    let _seat: wl_seat::WlSeat = registry.bind(id, version.min(7), &queue.handle(), ());
    let (id, version) = probe.global("wl_output")?;
    let _output: wl_output::WlOutput = registry.bind(id, version.min(4), &queue.handle(), ());
    let window = create_window(&connection, &queue, &probe)?;
    let (id, version) = probe.global("wl_compositor")?;
    let compositor: wl_compositor::WlCompositor =
        registry.bind(id, version.min(6), &queue.handle(), ());
    let (id, _) = probe.global("wl_subcompositor")?;
    let subs: wl_subcompositor::WlSubcompositor = registry.bind(id, 1, &queue.handle(), ());
    let hidden = compositor.create_surface(&queue.handle(), ());
    let hidden_role = subs.get_subsurface(&hidden, &window.surface, &queue.handle(), ());
    hidden.frame(&queue.handle(), Callback::HiddenFrame);
    hidden.commit();
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    let mut buffers = Vec::new();
    for pass in 0..2 {
        if pass != 0 {
            pump_until(&connection, &mut queue, &mut probe, |probe| {
                probe.sizes.contains(&(700, 500))
            })?;
        }
        let (width, height) = *probe.sizes.last().ok_or("missing graphics configure")?;
        assert!(width > 0 && height > 0);
        window
            .xdg
            .ack_configure(*probe.configures.last().ok_or("configure serial missing")?);
        let buffer = quadrants(&connection, &queue, &probe, width, height)?;
        window.xdg.set_window_geometry(0, 0, width, height);
        window.surface.attach(Some(&buffer), 0, 0);
        window.surface.damage_buffer(0, 0, width, height);
        let before = probe.frames;
        window.surface.frame(&queue.handle(), Callback::Frame);
        window.surface.commit();
        buffers.push(buffer);
        pump_until(&connection, &mut queue, &mut probe, |probe| {
            probe.frames > before
        })?;
        assert!(
            probe.output_enters > 0,
            "mapped surface must enter the output"
        );
        fs::write(
            control.join(if pass == 0 {
                "client-ready"
            } else {
                "client-resized"
            }),
            format!("{width} {height}"),
        )?;
        if pass == 0 {
            pump_until(&connection, &mut queue, &mut probe, |probe| {
                probe
                    .keys
                    .contains(&(30, WEnum::Value(wl_keyboard::KeyState::Pressed)))
                    && probe
                        .keys
                        .contains(&(30, WEnum::Value(wl_keyboard::KeyState::Released)))
                    && probe.motions > 0
                    && probe
                        .buttons
                        .contains(&(0x110, WEnum::Value(wl_pointer::ButtonState::Pressed)))
                    && probe
                        .buttons
                        .contains(&(0x110, WEnum::Value(wl_pointer::ButtonState::Released)))
            })?;
            assert!(probe.keyboard_enters > 0);
            fs::write(
                control.join("client-input"),
                "keyboard/pointer press and release observed",
            )?;
        }
    }
    pump_until(&connection, &mut queue, &mut probe, |_| {
        control.join("finish").exists()
    })?;
    assert!(
        probe.modes.contains(&(700, 500)),
        "wl_output must publish resize"
    );
    assert_eq!(
        probe.hidden_frames, 0,
        "a bufferless subsurface was not rendered and must not get frame done"
    );
    window.surface.attach(None, 0, 0);
    window.surface.commit();
    roundtrip(&connection, &mut queue, &mut probe)?;
    assert!(probe.output_leaves > 0);
    assert!(probe.keyboard_leaves > 0);
    assert!(probe.pointer_leaves > 0);
    hidden_role.destroy();
    hidden.destroy();
    window.top.destroy();
    window.xdg.destroy();
    window.surface.destroy();
    window.buffer.destroy();
    for buffer in buffers {
        buffer.destroy();
    }
    roundtrip(&connection, &mut queue, &mut probe)?;
    fs::write(control.join("client-done"), "unmapped and destroyed")?;
    Ok(())
}
