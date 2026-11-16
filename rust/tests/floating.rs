//! Stage 3 protocol and graphics qualification. Every Peer is a different
//! Wayland client; assertions use wire events and submitted pixels, not core IDs.
use super::*;
use wayland_protocols::xdg::shell::client::{xdg_popup, xdg_positioner};

delegate_noop!(Probe: ignore xdg_positioner::XdgPositioner);

impl Dispatch<xdg_popup::XdgPopup, ()> for Probe {
    fn event(
        state: &mut Self,
        popup: &xdg_popup::XdgPopup,
        event: xdg_popup::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            xdg_popup::Event::Configure {
                x,
                y,
                width,
                height,
            } => state
                .popup_geometry
                .push((popup.clone(), (x, y, width, height))),
            xdg_popup::Event::PopupDone => state.popup_done.push(popup.clone()),
            xdg_popup::Event::Repositioned { token } => state.repositioned.push(token),
            _ => {}
        }
    }
}

pub(crate) struct Peer {
    pub(crate) connection: Connection,
    pub(crate) queue: EventQueue<Probe>,
    pub(crate) probe: Probe,
    pub(crate) window: ClientWindow,
    pub(crate) compositor: wl_compositor::WlCompositor,
    pub(crate) shell: xdg_wm_base::XdgWmBase,
    pub(crate) shm: wl_shm::WlShm,
    pub(crate) seat: Option<wl_seat::WlSeat>,
    pub(crate) color: u32,
    pub(crate) size: (i32, i32),
    #[cfg(feature = "winit")]
    next_barrier: u32,
}

impl Peer {
    pub(crate) fn new(socket: &std::path::Path, color: u32) -> Result<Self> {
        let connection = Connection::from_socket(UnixStream::connect(socket)?)?;
        let mut queue = connection.new_event_queue();
        let qh = queue.handle();
        let registry = connection.display().get_registry(&qh, ());
        let mut probe = Probe::default();
        roundtrip(&connection, &mut queue, &mut probe)?;
        let (id, version) = probe.global("wl_compositor")?;
        let compositor = registry.bind(id, version.min(6), &qh, ());
        let (id, version) = probe.global("xdg_wm_base")?;
        let shell = registry.bind(id, version.min(6), &qh, ());
        let (id, _) = probe.global("wl_shm")?;
        let shm = registry.bind(id, 1, &qh, ());
        let seat = probe
            .global("wl_seat")
            .ok()
            .map(|(id, version)| registry.bind(id, version.min(7), &qh, ()));
        let window = create_window(&connection, &queue, &probe)?;
        let mut peer = Self {
            connection,
            queue,
            probe,
            window,
            compositor,
            shell,
            shm,
            seat,
            color,
            size: (320, 240),
            #[cfg(feature = "winit")]
            next_barrier: 0,
        };
        peer.window.surface.commit();
        peer.sync()?;
        assert!(!peer.probe.configures.is_empty());
        peer.draw((320, 240))?;
        peer.sync()?;
        Ok(peer)
    }

    pub(crate) fn sync(&mut self) -> Result<()> {
        roundtrip(&self.connection, &mut self.queue, &mut self.probe)
    }

    pub(crate) fn buffer(&self, size: (i32, i32), color: u32) -> Result<wl_buffer::WlBuffer> {
        let (w, h) = size;
        assert!(w > 0 && h > 0 && w <= 2048 && h <= 2048);
        let bytes = color.to_ne_bytes().repeat((w * h) as usize);
        let mut file = tempfile::tempfile()?;
        file.write_all(&bytes)?;
        let qh = self.queue.handle();
        let pool = self
            .shm
            .create_pool(file.as_fd(), bytes.len() as i32, &qh, ());
        let buffer = pool.create_buffer(0, w, h, w * 4, wl_shm::Format::Argb8888, &qh, ());
        pool.destroy();
        Ok(buffer)
    }

    pub(crate) fn ack(&mut self, xdg: &xdg_surface::XdgSurface) -> Result<()> {
        let serial = self
            .probe
            .surface_configures
            .iter()
            .rev()
            .find(|(surface, _)| surface == xdg)
            .map(|(_, serial)| *serial);
        if let Some(serial) = serial {
            xdg.ack_configure(serial);
            self.probe
                .surface_configures
                .retain(|(surface, _)| surface != xdg);
        }
        Ok(())
    }

    pub(crate) fn draw(&mut self, size: (i32, i32)) -> Result<()> {
        self.ack(&self.window.xdg.clone())?;
        let buffer = self.buffer(size, self.color)?;
        self.window
            .surface
            .frame(&self.queue.handle(), Callback::Frame);
        self.window.surface.attach(Some(&buffer), 0, 0);
        self.window.surface.damage_buffer(0, 0, size.0, size.1);
        self.window.surface.commit();
        std::mem::replace(&mut self.window.buffer, buffer).destroy();
        self.size = size;
        Ok(())
    }

    pub(crate) fn destroy(&self) {
        self.window.top.destroy();
        self.window.xdg.destroy();
        self.window.surface.destroy();
        self.window.buffer.destroy();
    }

    pub(crate) fn positioner(
        &self,
        size: (i32, i32),
        anchor: (i32, i32),
    ) -> xdg_positioner::XdgPositioner {
        let positioner = self.shell.create_positioner(&self.queue.handle(), ());
        positioner.set_size(size.0, size.1);
        positioner.set_anchor_rect(anchor.0, anchor.1, 1, 1);
        positioner.set_anchor(xdg_positioner::Anchor::BottomRight);
        positioner.set_gravity(xdg_positioner::Gravity::BottomRight);
        positioner.set_constraint_adjustment(
            xdg_positioner::ConstraintAdjustment::SlideX
                | xdg_positioner::ConstraintAdjustment::SlideY,
        );
        positioner.set_reactive();
        positioner
    }

    pub(crate) fn popup(
        &self,
        parent: &xdg_surface::XdgSurface,
        size: (i32, i32),
        anchor: (i32, i32),
    ) -> Popup {
        let surface = self.compositor.create_surface(&self.queue.handle(), ());
        let xdg = self
            .shell
            .get_xdg_surface(&surface, &self.queue.handle(), ());
        let positioner = self.positioner(size, anchor);
        let popup = xdg.get_popup(Some(parent), &positioner, &self.queue.handle(), ());
        positioner.destroy();
        Popup {
            surface,
            xdg,
            popup,
            size,
        }
    }

    pub(crate) fn map_popup(&mut self, popup: &Popup, color: u32) -> Result<()> {
        popup.surface.commit();
        self.sync()?;
        self.ack(&popup.xdg)?;
        let buffer = self.buffer(popup.size, color)?;
        popup.surface.frame(&self.queue.handle(), Callback::Frame);
        popup.surface.attach(Some(&buffer), 0, 0);
        popup
            .surface
            .damage_buffer(0, 0, popup.size.0, popup.size.1);
        popup.surface.commit();
        buffer.destroy();
        self.sync()
    }
}

pub(crate) struct Popup {
    pub(crate) surface: wl_surface::WlSurface,
    pub(crate) xdg: xdg_surface::XdgSurface,
    pub(crate) popup: xdg_popup::XdgPopup,
    pub(crate) size: (i32, i32),
}

impl Popup {
    pub(crate) fn destroy(&self) {
        self.popup.destroy();
        self.xdg.destroy();
        self.surface.destroy();
    }
}

#[test]
fn three_clients_remap_middle_destroy_and_disconnect() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut a = Peer::new(&server.socket, 0xffff0000)?;
    assert!(
        a.seat.is_none(),
        "headless intentionally has no seat global"
    );
    let mut b = Peer::new(&server.socket, 0xff00ff00)?;
    let c = Peer::new(&server.socket, 0xff0000ff)?;
    b.window.surface.attach(None, 0, 0);
    b.window.surface.commit();
    b.sync()?;
    b.window.surface.commit();
    b.sync()?;
    b.draw((260, 180))?;
    b.sync()?;
    b.destroy();
    b.sync()?;
    drop(c); // active client connection, including its registry and buffers
    a.sync()?;
    for _ in 0..16 {
        let mut temporary = Peer::new(&server.socket, 0xffffffff)?;
        temporary.destroy();
        temporary.sync()?;
    }
    a.draw((310, 230))?;
    a.sync()?;
    assert!(server.log()?.contains("Window unmapped"));
    assert!(server.log()?.matches("Window mapped").count() >= 20);
    server.stop(Signal::TERM)
}

#[test]
fn popup_configure_nested_reposition_and_parent_cleanup() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut peer = Peer::new(&server.socket, 0xffff0000)?;
    let popup = peer.popup(&peer.window.xdg, (120, 80), (200, 180));
    peer.map_popup(&popup, 0xffffff00)?;
    assert_eq!(
        peer.probe.popup_geometry.last().map(|(_, g)| *g),
        Some((201, 181, 120, 80))
    );
    let child = peer.popup(&popup.xdg, (60, 40), (100, 60));
    peer.map_popup(&child, 0xffff00ff)?;
    assert_eq!(
        peer.probe.popup_geometry.last().map(|(_, g)| *g),
        Some((101, 61, 60, 40))
    );
    let positioner = peer.positioner((120, 80), (50, 60));
    popup.popup.reposition(&positioner, 31337);
    positioner.destroy();
    peer.sync()?;
    assert!(peer.probe.repositioned.contains(&31337));
    assert_eq!(
        peer.probe.popup_geometry.last().map(|(_, g)| *g),
        Some((51, 61, 120, 80))
    );
    peer.ack(&popup.xdg)?;
    popup.surface.commit();
    peer.sync()?;
    peer.destroy();
    peer.sync()?;
    assert!(peer.probe.popup_done.contains(&popup.popup));
    assert!(peer.probe.popup_done.contains(&child.popup));
    assert_eq!(
        peer.probe.popup_done.len(),
        2,
        "dismiss each popup exactly once"
    );
    child.destroy();
    popup.destroy();
    peer.sync()?;
    let mut healthy = Peer::new(&server.socket, 0xff00ff00)?;
    healthy.sync()?;
    server.stop(Signal::TERM)
}

#[test]
fn popup_unacked_buffer_is_client_local_error() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut healthy = Peer::new(&server.socket, 0xffff0000)?;
    let mut bad = Peer::new(&server.socket, 0xff00ff00)?;
    let popup = bad.popup(&bad.window.xdg, (120, 80), (50, 60));
    popup.surface.commit();
    bad.sync()?;
    // No ACK: receiving configure is insufficient permission to map.
    popup.surface.attach(Some(&bad.window.buffer), 0, 0);
    popup.surface.commit();
    assert!(bad.sync().is_err());
    assert!(bad
        .connection
        .protocol_error()
        .is_some_and(|error| error.object_interface == "xdg_surface" && error.code == 3));
    healthy.draw((300, 200))?;
    healthy.sync()?;
    server.stop(Signal::TERM)
}

#[test]
fn invalid_popup_parents_and_unmapped_ancestor_are_isolated() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut healthy = Peer::new(&server.socket, 0xffff0000)?;
    for self_parent in [true, false] {
        let mut bad = Peer::new(&server.socket, 0xff00ff00)?;
        let surface = bad.compositor.create_surface(&bad.queue.handle(), ());
        let xdg = bad.shell.get_xdg_surface(&surface, &bad.queue.handle(), ());
        let parent = bad.shell.get_xdg_surface(
            &bad.compositor.create_surface(&bad.queue.handle(), ()),
            &bad.queue.handle(),
            (),
        );
        let positioner = bad.positioner((100, 70), (20, 20));
        let _popup = xdg.get_popup(
            Some(if self_parent { &xdg } else { &parent }),
            &positioner,
            &bad.queue.handle(),
            (),
        );
        assert!(bad.sync().is_err());
        assert!(bad
            .connection
            .protocol_error()
            .is_some_and(|error| error.object_interface == "xdg_wm_base" && error.code == 3));
        healthy.sync()?;
    }
    // A live popup role alone does not make it an eligible mapped parent.
    let mut bad = Peer::new(&server.socket, 0xff00ff00)?;
    let parent = bad.popup(&bad.window.xdg, (120, 80), (20, 20));
    parent.surface.commit();
    bad.sync()?;
    let child = bad.popup(&parent.xdg, (60, 40), (20, 20));
    child.surface.commit();
    bad.sync()?;
    bad.ack(&child.xdg)?;
    child.surface.attach(Some(&bad.window.buffer), 0, 0);
    child.surface.commit();
    assert!(bad.sync().is_err());
    assert!(bad
        .connection
        .protocol_error()
        .is_some_and(|error| error.object_interface == "xdg_wm_base" && error.code == 3));
    healthy.sync()?;
    server.stop(Signal::TERM)
}

#[test]
fn popup_null_buffer_dismisses_live_descendants() -> Result<()> {
    let mut server = Server::start(None)?;
    let mut peer = Peer::new(&server.socket, 0xffff0000)?;
    let parent = peer.popup(&peer.window.xdg, (120, 80), (20, 20));
    peer.map_popup(&parent, 0xffffff00)?;
    let child = peer.popup(&parent.xdg, (60, 40), (20, 20));
    peer.map_popup(&child, 0xffff00ff)?;
    parent.surface.attach(None, 0, 0);
    parent.surface.commit();
    peer.sync()?;
    assert!(peer.probe.popup_done.contains(&parent.popup));
    assert!(peer.probe.popup_done.contains(&child.popup));
    assert_eq!(peer.probe.popup_done.len(), 2);
    child.destroy();
    parent.destroy();
    peer.sync()?;
    peer.draw((300, 200))?;
    peer.sync()?;
    server.stop(Signal::TERM)
}

#[cfg(feature = "winit")]
fn until(peer: &mut Peer, predicate: impl Fn(&Probe) -> bool) -> Result<()> {
    pump_until(
        &peer.connection,
        &mut peer.queue,
        &mut peer.probe,
        predicate,
    )
}

#[cfg(feature = "winit")]
fn marker(control: &std::path::Path, name: &str) -> Result<()> {
    fs::write(control.join(name), name)?;
    println!("stage3: {name}");
    Ok(())
}

#[cfg(feature = "winit")]
fn gate(peer: &mut Peer, control: &std::path::Path, name: &str) -> Result<()> {
    until(peer, |_| control.join(name).exists())
}

#[cfg(feature = "winit")]
fn submitted(peer: &mut Peer) -> Result<()> {
    peer.draw(peer.size)?;
    submitted_surface(peer, &peer.window.surface.clone())
}

#[cfg(feature = "winit")]
fn submitted_surface(peer: &mut Peer, surface: &wl_surface::WlSurface) -> Result<()> {
    peer.next_barrier += 1;
    let token = peer.next_barrier;
    surface.frame(&peer.queue.handle(), Callback::Barrier(token));
    surface.commit();
    until(peer, |probe| probe.barriers.contains(&token))
}

#[cfg(feature = "winit")]
fn press(peer: &mut Peer) -> Result<u32> {
    let before = peer.probe.input_serials.len();
    until(peer, |probe| {
        probe.input_serials.len() > before
            && probe
                .input_serials
                .last()
                .is_some_and(|(_, state)| *state == WEnum::Value(wl_pointer::ButtonState::Pressed))
    })?;
    Ok(peer
        .probe
        .input_serials
        .last()
        .ok_or("missing pointer serial")?
        .0)
}

#[test]
#[cfg(feature = "winit")]
#[ignore = "requires nested-smoke.py --stage3 and its private input driver"]
fn nested_floating_focus_geometry_and_popups() -> Result<()> {
    let socket = PathBuf::from(std::env::var_os("RAYWM_SMOKE_SOCKET").ok_or("run harness")?);
    let control = PathBuf::from(std::env::var_os("RAYWM_SMOKE_CONTROL").ok_or("run harness")?);
    let mut a = Peer::new(&socket, 0xffff0000)?;
    let mut b = Peer::new(&socket, 0xff00ff00)?;
    let mut c = Peer::new(&socket, 0xff0000ff)?;
    until(&mut c, |p| p.activated && p.keyboard_focus.is_some())?;
    a.sync()?;
    b.sync()?;
    assert!(!a.probe.activated && !b.probe.activated);
    submitted(&mut c)?;
    marker(&control, "three-ready")?;
    until(&mut a, |p| {
        p.activated
            && p.keys
                .contains(&(30, WEnum::Value(wl_keyboard::KeyState::Released)))
    })?;
    b.sync()?;
    c.sync()?;
    assert_eq!(a.probe.keyboard_focus, Some(a.window.surface.clone()));
    assert!(!b.probe.activated && !c.probe.activated);
    assert!(b.probe.keys.is_empty() && c.probe.keys.is_empty());
    submitted(&mut a)?;
    marker(&control, "focus-ready")?;

    let stale = press(&mut a)?;
    a.window
        .top
        ._move(a.seat.as_ref().ok_or("missing seat")?, stale);
    a.connection.flush()?;
    gate(&mut a, &control, "move-driven")?;
    submitted(&mut a)?;
    marker(&control, "move-ready")?;
    // During a different, live implicit grab, neither an old serial nor a
    // serial observed by a different client may start a compositor operation.
    let foreign = press(&mut a)?;
    a.window
        .top
        ._move(a.seat.as_ref().ok_or("missing seat")?, stale);
    b.window
        .top
        ._move(b.seat.as_ref().ok_or("missing seat")?, foreign);
    a.connection.flush()?;
    b.connection.flush()?;
    gate(&mut a, &control, "invalid-driven")?;
    submitted(&mut a)?;
    marker(&control, "invalid-ready")?;

    a.window.top.set_min_size(200, 150);
    a.window.top.set_max_size(420, 300);
    a.window.surface.commit();
    a.sync()?;
    marker(&control, "resize-armed")?;
    let serial = press(&mut a)?;
    let before = a.probe.sizes.len();
    a.window.top.resize(
        a.seat.as_ref().ok_or("missing seat")?,
        serial,
        xdg_toplevel::ResizeEdge::TopLeft,
    );
    a.connection.flush()?;
    gate(&mut a, &control, "resize-driven")?;
    assert!(a.probe.resizing);
    assert!(
        a.probe.sizes.len() - before <= 2,
        "configure flow must be bounded without ACK/commit"
    );
    marker(&control, "resize-unacked")?;
    gate(&mut a, &control, "resize-ack")?;
    a.draw(a.size)?; // ACK + commit the first in-flight size.
    until(&mut a, |p| {
        p.sizes.last() == Some(&(220, 150)) && !p.resizing
    })?;
    a.draw((220, 150))?;
    submitted(&mut a)?;
    marker(&control, "resize-ready")?;
    let serial = press(&mut a)?;
    a.window.top.resize(
        a.seat.as_ref().ok_or("missing seat")?,
        serial,
        xdg_toplevel::ResizeEdge::BottomRight,
    );
    a.connection.flush()?;
    gate(&mut a, &control, "max-driven")?;
    a.draw(a.size)?;
    until(&mut a, |p| {
        p.sizes.last() == Some(&(420, 300)) && !p.resizing
    })?;
    a.draw((420, 300))?;
    submitted(&mut a)?;
    marker(&control, "max-ready")?;

    // Grab requests happen before initial commit, while the initiating press
    // is still held. Popup geometry is constrained in output coordinates.
    let serial = press(&mut a)?;
    let popup = a.popup(&a.window.xdg, (140, 90), (419, 299));
    popup
        .popup
        .grab(a.seat.as_ref().ok_or("missing seat")?, serial);
    a.map_popup(&popup, 0xffffff00)?;
    let geometry = a
        .probe
        .popup_geometry
        .last()
        .ok_or("popup configure missing")?
        .1;
    assert_eq!(geometry, (410, 300, 140, 90)); // parent at (250,190), constrained to (660,490)
    let nested = a.popup(&popup.xdg, (80, 50), (139, 89));
    nested
        .popup
        .grab(a.seat.as_ref().ok_or("missing seat")?, serial);
    a.map_popup(&nested, 0xffff00ff)?;
    submitted_surface(&mut a, &nested.surface)?;
    assert_eq!(
        a.probe.popup_geometry.last().map(|(_, g)| *g),
        Some((60, 60, 80, 50))
    );
    until(&mut a, |p| p.keyboard_focus == Some(nested.surface.clone()))?;
    marker(&control, "popup-ready")?;
    gate(&mut a, &control, "popup-key-driven")?;
    assert!(a
        .probe
        .keys
        .contains(&(48, WEnum::Value(wl_keyboard::KeyState::Released))));
    assert_eq!(a.probe.keyboard_focus, Some(nested.surface.clone()));
    assert_eq!(a.probe.pointer_focus, Some(nested.surface.clone()));
    assert!(
        a.probe
            .pointer_position
            .is_some_and(|(x, y)| (x - 10.).abs() < 1. && (y - 10.).abs() < 1.),
        "nested popup pointer coordinates must be local: {:?}",
        a.probe.pointer_position
    );
    let positioner = a.positioner((80, 50), (0, 0));
    nested.popup.reposition(&positioner, 777);
    positioner.destroy();
    until(&mut a, |p| p.repositioned.contains(&777))?;
    a.ack(&nested.xdg)?;
    submitted_surface(&mut a, &nested.surface)?;
    marker(&control, "reposition-ready")?;
    until(&mut a, |p| {
        p.popup_done.contains(&popup.popup) && p.popup_done.contains(&nested.popup)
    })?;
    let target = a.window.surface.clone();
    until(&mut a, |p| p.keyboard_focus == Some(target.clone()))?;
    nested.destroy();
    popup.destroy();
    a.sync()?;
    submitted(&mut a)?;
    marker(&control, "dismiss-ready")?;

    // Wrong serial is rejected without leaving a partially active grab.
    let rejected = a.popup(&a.window.xdg, (100, 70), (20, 20));
    rejected
        .popup
        .grab(a.seat.as_ref().ok_or("missing seat")?, stale);
    a.sync()?;
    assert!(a.probe.popup_done.contains(&rejected.popup));
    rejected.destroy();
    a.sync()?;
    marker(&control, "parent-armed")?;
    let serial = press(&mut a)?;
    let popup = a.popup(&a.window.xdg, (100, 70), (20, 20));
    popup
        .popup
        .grab(a.seat.as_ref().ok_or("missing seat")?, serial);
    a.map_popup(&popup, 0xffffff00)?;
    marker(&control, "parent-popup-ready")?;
    gate(&mut a, &control, "destroy-parent")?;
    a.destroy();
    a.sync()?;
    assert!(a.probe.popup_done.contains(&popup.popup));
    popup.destroy();
    a.sync()?;
    let target = c.window.surface.clone();
    until(&mut c, |p| {
        p.activated && p.keyboard_focus == Some(target.clone())
    })?;
    submitted(&mut c)?;
    marker(&control, "parent-destroyed")?;

    marker(&control, "keyboard-popup-armed")?;
    until(&mut c, |p| p.key_serial.is_some())?;
    let serial = c.probe.key_serial.ok_or("keyboard press serial missing")?;
    let popup = c.popup(&c.window.xdg, (100, 70), (20, 20));
    popup
        .popup
        .grab(c.seat.as_ref().ok_or("missing seat")?, serial);
    c.map_popup(&popup, 0xffffff00)?;
    submitted_surface(&mut c, &popup.surface)?;
    until(&mut c, |p| p.keyboard_focus == Some(popup.surface.clone()))?;
    let mut newcomer = Peer::new(&socket, 0xff0000ff)?;
    newcomer.sync()?;
    c.sync()?;
    assert!(
        !newcomer.probe.activated,
        "new map must respect an existing popup grab"
    );
    assert_eq!(c.probe.keyboard_focus, Some(popup.surface.clone()));
    marker(&control, "keyboard-popup-ready")?;
    gate(&mut c, &control, "disconnect-popup")?;
    drop(c); // including a mapped, explicitly grabbed popup and live parent
    drop(popup);
    let mut c = newcomer;
    let target = c.window.surface.clone();
    until(&mut c, |p| {
        p.activated && p.keyboard_focus == Some(target.clone())
    })?;
    submitted(&mut c)?;
    marker(&control, "popup-disconnected")?;

    marker(&control, "unmap-armed")?;
    let serial = press(&mut c)?;
    c.window.top.resize(
        c.seat.as_ref().ok_or("missing seat")?,
        serial,
        xdg_toplevel::ResizeEdge::Left,
    );
    c.connection.flush()?;
    until(&mut c, |p| p.resizing)?;
    c.window.surface.attach(None, 0, 0);
    c.window.surface.commit();
    c.sync()?;
    c.window.surface.commit();
    c.sync()?;
    c.draw(c.size)?;
    submitted(&mut c)?;
    assert!(
        !c.probe.resizing,
        "remap must clear the canceled resize state"
    );
    marker(&control, "unmap-remapped")?;
    gate(&mut c, &control, "unmap-driven")?;
    assert!(
        !c.probe
            .buttons
            .iter()
            .any(|(_, state)| *state == WEnum::Value(wl_pointer::ButtonState::Released)),
        "release from an unmapped grab must not leak into remap"
    );

    // Destroy a middle window, then remove the active window mid-resize.
    b.destroy();
    b.sync()?;
    marker(&control, "disconnect-armed")?;
    let serial = press(&mut c)?;
    c.window.top.resize(
        c.seat.as_ref().ok_or("missing seat")?,
        serial,
        xdg_toplevel::ResizeEdge::Right,
    );
    c.connection.flush()?;
    until(&mut c, |p| p.resizing)?;
    drop(c);
    // Independent connection remains responsive with no stale seat target.
    let mut survivor = Peer::new(&socket, 0xff00ffff)?;
    gate(&mut survivor, &control, "disconnect-driven")?;
    let target = survivor.window.surface.clone();
    until(&mut survivor, |p| p.keyboard_focus == Some(target.clone()))?;
    assert!(
        !survivor
            .probe
            .buttons
            .iter()
            .any(|(_, state)| *state == WEnum::Value(wl_pointer::ButtonState::Released)),
        "orphaned release must not be delivered to a newly mapped client"
    );
    submitted(&mut survivor)?;
    marker(&control, "survivor-ready")?;
    gate(&mut survivor, &control, "finish")?;
    survivor.destroy();
    survivor.sync()?;
    marker(&control, "client-done")
}
