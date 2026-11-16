//! Stage 4A clipboard, primary-selection and focus regression tests.
//!
//! The headless test exercises the advertised managers and source teardown.
//! The graphical test (run by `selection-smoke.py`) uses independent Wayland
//! clients, real keyboard focus transitions and real fd transfers. Nothing
//! here touches Smithay's internal selection state directly.

#[cfg(feature = "winit")]
use super::floating::Peer;
use super::*;
use std::{fs, os::fd::OwnedFd};
#[cfg(feature = "winit")]
use std::{
    io::Read,
    os::fd::AsFd,
    path::Path,
    time::{Duration, Instant},
};
use wayland_client::{
    delegate_noop, event_created_child,
    protocol::{wl_data_device::WlDataDevice, wl_data_source::WlDataSource},
};

delegate_noop!(Probe: ignore wl_data_device_manager::WlDataDeviceManager);
delegate_noop!(Probe: ignore ZwpPrimarySelectionDeviceManagerV1);
use wayland_protocols::wp::primary_selection::zv1::client::{
    zwp_primary_selection_device_manager_v1::ZwpPrimarySelectionDeviceManagerV1,
    zwp_primary_selection_device_v1::ZwpPrimarySelectionDeviceV1,
    zwp_primary_selection_offer_v1::ZwpPrimarySelectionOfferV1,
    zwp_primary_selection_source_v1::ZwpPrimarySelectionSourceV1,
};

/// Payloads are keyed by mime type so a test can prove that the requested
/// type, not a cached buffer, determines the bytes transferred.
#[derive(Clone, Default)]
pub(crate) struct SourceData {
    payloads: Vec<(String, Vec<u8>)>,
}

impl SourceData {
    pub(crate) fn new(payloads: &[(&str, &[u8])]) -> Self {
        Self {
            payloads: payloads
                .iter()
                .map(|(mime, data)| ((*mime).to_string(), data.to_vec()))
                .collect(),
        }
    }

    pub(crate) fn payload(&self, mime: &str) -> &[u8] {
        self.payloads
            .iter()
            .find(|(known, _)| known == mime)
            .map(|(_, data)| data.as_slice())
            .unwrap_or_default()
    }
}

fn deliver(state: &mut Probe, mime: String, fd: OwnedFd, data: &SourceData, primary: bool) {
    let mut file = fs::File::from(fd);
    match file.write_all(data.payload(&mime)) {
        Ok(()) => {
            let length = data.payload(&mime).len();
            if primary {
                state.primary_sends.push((mime, length));
            } else {
                state.source_sends.push((mime, length));
            }
        }
        Err(_) => {
            if primary {
                state.primary_send_errors += 1;
            } else {
                state.source_send_errors += 1;
            }
        }
    }
}

impl Dispatch<wl_data_device::WlDataDevice, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &WlDataDevice,
        event: wl_data_device::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_data_device::Event::Selection { id } => state.clipboard_selection.push(id),
            wl_data_device::Event::Enter {
                serial,
                surface,
                x,
                y,
                id,
            } => state.dnd_enters.push((serial, surface, id, x, y)),
            wl_data_device::Event::Leave => state.dnd_leaves += 1,
            wl_data_device::Event::Motion { x, y, .. } => state.dnd_motions.push((x, y)),
            wl_data_device::Event::Drop => state.dnd_drops += 1,
            _ => {}
        }
    }

    event_created_child!(Probe, wl_data_device::WlDataDevice, [
        wl_data_device::EVT_DATA_OFFER_OPCODE => (wl_data_offer::WlDataOffer, ()),
    ]);
}

impl Dispatch<wl_data_offer::WlDataOffer, ()> for Probe {
    fn event(
        state: &mut Self,
        offer: &wl_data_offer::WlDataOffer,
        event: wl_data_offer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_data_offer::Event::Offer { mime_type } => {
                state.offer_mime_types.push((offer.clone(), mime_type));
            }
            wl_data_offer::Event::SourceActions { source_actions } => {
                state
                    .offer_source_actions
                    .push((offer.clone(), source_actions));
            }
            wl_data_offer::Event::Action { dnd_action } => {
                state.offer_actions.push((offer.clone(), dnd_action));
            }
            _ => {}
        }
    }
}

impl Dispatch<WlDataSource, SourceData> for Probe {
    fn event(
        state: &mut Self,
        _: &WlDataSource,
        event: wl_data_source::Event,
        data: &SourceData,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            wl_data_source::Event::Target { mime_type } => state.source_targets.push(mime_type),
            wl_data_source::Event::Send { mime_type, fd } => {
                deliver(state, mime_type, fd, data, false);
            }
            wl_data_source::Event::Cancelled => state.source_cancelled += 1,
            wl_data_source::Event::DndDropPerformed => state.source_drop_performed += 1,
            wl_data_source::Event::DndFinished => state.source_finished += 1,
            wl_data_source::Event::Action { dnd_action } => {
                state.source_actions.push(dnd_action);
            }
            _ => {}
        }
    }
}

impl Dispatch<ZwpPrimarySelectionDeviceV1, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &ZwpPrimarySelectionDeviceV1,
        event: zwp_primary_selection_device_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zwp_primary_selection_device_v1::Event::DataOffer { offer: _ } => {
                state.primary_selection.push(None);
            }
            zwp_primary_selection_device_v1::Event::Selection { id } => {
                state.primary_selection.push(id);
            }
            _ => {}
        }
    }

    event_created_child!(Probe, ZwpPrimarySelectionDeviceV1, [
        zwp_primary_selection_device_v1::EVT_DATA_OFFER_OPCODE
            => (ZwpPrimarySelectionOfferV1, ()),
    ]);
}

impl Dispatch<ZwpPrimarySelectionOfferV1, ()> for Probe {
    fn event(
        state: &mut Self,
        offer: &ZwpPrimarySelectionOfferV1,
        event: zwp_primary_selection_offer_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let zwp_primary_selection_offer_v1::Event::Offer { mime_type } = event {
            state
                .primary_offer_mime_types
                .push((offer.clone(), mime_type));
        }
    }
}

impl Dispatch<ZwpPrimarySelectionSourceV1, SourceData> for Probe {
    fn event(
        state: &mut Self,
        _: &ZwpPrimarySelectionSourceV1,
        event: zwp_primary_selection_source_v1::Event,
        data: &SourceData,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zwp_primary_selection_source_v1::Event::Send { mime_type, fd } => {
                deliver(state, mime_type, fd, data, true);
            }
            zwp_primary_selection_source_v1::Event::Cancelled => state.primary_cancelled += 1,
            _ => {}
        }
    }
}

#[test]
fn selection_managers_and_source_teardown_are_isolated() -> Result<()> {
    let mut server = Server::start(Some("selection"))?;
    let (connection, mut queue, mut probe) = server.connect()?;
    assert_eq!(probe.global("wl_data_device_manager")?.1, 3);
    assert_eq!(
        probe.global("zwp_primary_selection_device_manager_v1")?.1,
        1
    );
    let qh = queue.handle();
    let registry = connection.display().get_registry(&qh, ());
    let (id, version) = probe.global("wl_data_device_manager")?;
    let manager: wl_data_device_manager::WlDataDeviceManager =
        registry.bind(id, version.min(3), &qh, ());
    let source = manager.create_data_source(
        &qh,
        SourceData::new(&[
            ("text/plain;charset=utf-8", b"utf8"),
            ("text/plain", b"plain"),
        ]),
    );
    source.offer("text/plain;charset=utf-8".into());
    source.offer("text/plain".into());
    let (id, version) = probe.global("zwp_primary_selection_device_manager_v1")?;
    let primary_manager: ZwpPrimarySelectionDeviceManagerV1 =
        registry.bind(id, version.min(1), &qh, ());
    let primary =
        primary_manager.create_source(&qh, SourceData::new(&[("text/plain", b"primary")]));
    primary.offer("text/plain".into());
    roundtrip(&connection, &mut queue, &mut probe)?;

    // Destroying an unattached source must not disturb the global or a
    // following independent client.
    source.destroy();
    primary.destroy();
    roundtrip(&connection, &mut queue, &mut probe)?;
    let (other, mut other_queue, mut other_probe) = server.connect()?;
    roundtrip(&other, &mut other_queue, &mut other_probe)?;
    drop(other);
    roundtrip(&connection, &mut queue, &mut probe)?;
    let sources = manager.create_data_source(&qh, SourceData::default());
    sources.destroy();
    roundtrip(&connection, &mut queue, &mut probe)?;
    server.stop(Signal::TERM)
}

// ---------------------------------------------------------------------------
// Graphical qualification

#[cfg(feature = "winit")]
pub(crate) fn click(control: &Path, name: &str, at: (i32, i32)) -> Result<()> {
    fs::write(
        control.join(format!("want-{name}")),
        format!("move {} {} down left up left sleep 80", at.0, at.1),
    )?;
    let done = control.join(format!("{name}-done"));
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done.exists() {
        if Instant::now() >= deadline {
            return Err(format!("input gate {name} timed out").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

#[cfg(feature = "winit")]
fn key_press(control: &Path, name: &str, key: &str) -> Result<()> {
    fs::write(
        control.join(format!("want-{name}")),
        format!("key {key} down key {key} up sleep 80"),
    )?;
    let done = control.join(format!("{name}-done"));
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done.exists() {
        if Instant::now() >= deadline {
            return Err(format!("input gate {name} timed out").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

#[cfg(feature = "winit")]
fn wait_key(peer: &mut Peer) -> Result<u32> {
    let before = peer.probe.keys.len();
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        peer.sync()?;
        if peer.probe.keys[before..]
            .iter()
            .any(|(_, state)| *state == WEnum::Value(wl_keyboard::KeyState::Pressed))
        {
            return peer.probe.key_serial.ok_or_else(|| "no key serial".into());
        }
        if Instant::now() >= deadline {
            return Err("client did not receive a key press".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(feature = "winit")]
pub(crate) fn wait_focus(peer: &mut Peer, surface: &wl_surface::WlSurface) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        peer.sync()?;
        if peer.probe.keyboard_focus.as_ref() == Some(surface) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("client did not receive keyboard focus".into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(feature = "winit")]
pub(crate) fn focus(peer: &mut Peer, control: &Path, name: &str, at: (i32, i32)) -> Result<()> {
    let surface = peer.window.surface.clone();
    click(control, name, at)?;
    wait_focus(peer, &surface)
}

#[cfg(feature = "winit")]
pub(crate) fn clipboard_manager(
    peer: &Peer,
) -> Result<wl_data_device_manager::WlDataDeviceManager> {
    let registry = peer
        .connection
        .display()
        .get_registry(&peer.queue.handle(), ());
    let (id, version) = peer.probe.global("wl_data_device_manager")?;
    Ok(registry.bind(id, version.min(3), &peer.queue.handle(), ()))
}

#[cfg(feature = "winit")]
pub(crate) fn clipboard_device(peer: &Peer) -> Result<WlDataDevice> {
    let manager = clipboard_manager(peer)?;
    let seat = peer.seat.as_ref().ok_or("graphical client has no seat")?;
    Ok(manager.get_data_device(seat, &peer.queue.handle(), ()))
}

#[cfg(feature = "winit")]
pub(crate) fn primary_manager(peer: &Peer) -> Result<ZwpPrimarySelectionDeviceManagerV1> {
    let registry = peer
        .connection
        .display()
        .get_registry(&peer.queue.handle(), ());
    let (id, version) = peer
        .probe
        .global("zwp_primary_selection_device_manager_v1")?;
    Ok(registry.bind(id, version.min(1), &peer.queue.handle(), ()))
}

#[cfg(feature = "winit")]
pub(crate) fn primary_device(peer: &Peer) -> Result<ZwpPrimarySelectionDeviceV1> {
    let manager = primary_manager(peer)?;
    let seat = peer.seat.as_ref().ok_or("graphical client has no seat")?;
    Ok(manager.get_device(seat, &peer.queue.handle(), ()))
}

#[cfg(feature = "winit")]
pub(crate) fn clipboard_source(peer: &Peer, data: SourceData) -> Result<WlDataSource> {
    let manager = clipboard_manager(peer)?;
    let mimes = data
        .payloads
        .iter()
        .map(|(mime, _)| mime.clone())
        .collect::<Vec<_>>();
    let source = manager.create_data_source(&peer.queue.handle(), data);
    for mime in mimes {
        source.offer(mime);
    }
    Ok(source)
}

#[cfg(feature = "winit")]
pub(crate) fn primary_source(peer: &Peer, data: SourceData) -> Result<ZwpPrimarySelectionSourceV1> {
    let manager = primary_manager(peer)?;
    let mimes = data
        .payloads
        .iter()
        .map(|(mime, _)| mime.clone())
        .collect::<Vec<_>>();
    let source = manager.create_source(&peer.queue.handle(), data);
    for mime in mimes {
        source.offer(mime);
    }
    Ok(source)
}

#[cfg(feature = "winit")]
pub(crate) fn last_offer(
    events: &[Option<wl_data_offer::WlDataOffer>],
) -> Option<wl_data_offer::WlDataOffer> {
    events.last().cloned().flatten()
}

#[cfg(feature = "winit")]
pub(crate) fn mimes(probe: &Probe, offer: &wl_data_offer::WlDataOffer) -> Vec<String> {
    let mut list = probe
        .offer_mime_types
        .iter()
        .filter(|(known, _)| known == offer)
        .map(|(_, mime)| mime.clone())
        .collect::<Vec<_>>();
    list.sort();
    list
}

#[cfg(feature = "winit")]
pub(crate) fn read_clipboard(
    source: &mut Peer,
    receiver: &mut Peer,
    offer: &wl_data_offer::WlDataOffer,
    mime: &str,
) -> Result<Vec<u8>> {
    let (read, write) = UnixStream::pair()?;
    read.set_read_timeout(Some(WAIT))?;
    offer.receive(mime.to_string(), write.as_fd());
    receiver.connection.flush()?;
    receiver.sync()?;
    drop(write);
    source.sync()?;
    let mut data = Vec::new();
    let mut read = read;
    read.read_to_end(&mut data)?;
    Ok(data)
}

#[cfg(feature = "winit")]
pub(crate) fn read_local(
    peer: &mut Peer,
    offer: &wl_data_offer::WlDataOffer,
    mime: &str,
) -> Result<Vec<u8>> {
    let (read, write) = UnixStream::pair()?;
    read.set_read_timeout(Some(WAIT))?;
    offer.receive(mime.to_string(), write.as_fd());
    peer.connection.flush()?;
    peer.sync()?;
    peer.sync()?;
    drop(write);
    let mut data = Vec::new();
    let mut read = read;
    read.read_to_end(&mut data)?;
    Ok(data)
}

#[cfg(feature = "winit")]
pub(crate) fn read_primary(
    source: &mut Peer,
    receiver: &mut Peer,
    offer: &ZwpPrimarySelectionOfferV1,
    mime: &str,
) -> Result<Vec<u8>> {
    let (read, write) = UnixStream::pair()?;
    read.set_read_timeout(Some(WAIT))?;
    offer.receive(mime.to_string(), write.as_fd());
    receiver.connection.flush()?;
    receiver.sync()?;
    drop(write);
    source.sync()?;
    let mut data = Vec::new();
    let mut read = read;
    read.read_to_end(&mut data)?;
    Ok(data)
}

/// Click geometry follows the compositor's deterministic cascade: the first
/// live window is at 0,0, the next at 48,48 and so on. Each Peer draws 320x240.
#[cfg(feature = "winit")]
pub(crate) fn at(rank: i32) -> (i32, i32) {
    // Windows are 320x240 at a 48px cascade. The first window is clickable in
    // its left strip; later windows are clickable in the 48px strip to the
    // right of all earlier windows, so a raised window cannot hide the target.
    let x = if rank == 0 {
        20
    } else {
        320 + (rank - 1) * 48 + 20
    };
    (x, rank * 48 + 20)
}

#[test]
#[cfg(feature = "winit")]
#[ignore = "requires selection-smoke.py private graphical parent and input driver"]
fn clipboard_primary_and_focus_lifecycle() -> Result<()> {
    let socket = PathBuf::from(std::env::var_os("RAYWM_SMOKE_SOCKET").ok_or("run harness")?);
    let control = PathBuf::from(std::env::var_os("RAYWM_SMOKE_CONTROL").ok_or("run harness")?);
    let mut a = Peer::new(&socket, 0xffff0000)?;
    let mut b = Peer::new(&socket, 0xff00ff00)?;
    let b_surface = b.window.surface.clone();
    wait_focus(&mut b, &b_surface)?;
    let device_a = clipboard_device(&a)?;
    let device_b = clipboard_device(&b)?;
    let primary_a = primary_device(&a)?;
    let _primary_b = primary_device(&b)?;
    a.sync()?;
    b.sync()?;

    // --- Focus A and set the clipboard with a serial the compositor sent. ---
    focus(&mut a, &control, "focus-a", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let source = clipboard_source(
        &a,
        SourceData::new(&[
            ("text/plain;charset=utf-8", b"utf8-payload"),
            ("text/plain", b"plain-payload"),
            ("application/x-raywm", b"binary-payload"),
        ]),
    )?;
    device_a.set_selection(Some(&source), serial_a);
    a.sync()?;
    assert!(
        b.probe.clipboard_selection.is_empty()
            || b.probe.clipboard_selection.iter().all(Option::is_none),
        "an unfocused client must not receive another client's selection"
    );

    // --- Focus B: the selection is offered; request two real MIME types. ---
    focus(&mut b, &control, "focus-b", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("B received no clipboard offer")?;
    assert_eq!(
        mimes(&b.probe, &offer),
        [
            "application/x-raywm",
            "text/plain",
            "text/plain;charset=utf-8"
        ]
    );
    let utf8 = read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?;
    assert_eq!(utf8, b"utf8-payload");
    let plain = read_clipboard(&mut a, &mut b, &offer, "text/plain")?;
    assert_eq!(plain, b"plain-payload");
    let binary = read_clipboard(&mut a, &mut b, &offer, "application/x-raywm")?;
    assert_eq!(binary, b"binary-payload");

    // --- Self-copy: A regains focus and reads its own current selection. ---
    focus(&mut a, &control, "focus-a-2", at(0))?;
    let own = last_offer(&a.probe.clipboard_selection).ok_or("A received no own offer")?;
    assert_eq!(
        read_local(&mut a, &own, "text/plain")?.as_slice(),
        b"plain-payload"
    );

    // --- B takes ownership; A must observe the new selection on focus. ---
    focus(&mut b, &control, "focus-b-2", at(1))?;
    let serial_b = b.probe.keyboard_enter_serial.ok_or("no B enter serial")?;
    let b_source = clipboard_source(
        &b,
        SourceData::new(&[("text/plain;charset=utf-8", b"from-b")]),
    )?;
    device_b.set_selection(Some(&b_source), serial_b);
    b.sync()?;
    focus(&mut a, &control, "focus-a-3", at(0))?;
    let offer = last_offer(&a.probe.clipboard_selection).ok_or("A received no B offer")?;
    assert_eq!(
        read_clipboard(&mut b, &mut a, &offer, "text/plain;charset=utf-8")?,
        b"from-b"
    );

    // --- Unfocused receiver must not see later selection changes. ---
    let before = b.probe.clipboard_selection.len();
    focus(&mut a, &control, "focus-a-4", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"second-a")]),
    )?;
    device_a.set_selection(Some(&source), serial_a);
    a.sync()?;
    b.sync()?;
    assert_eq!(
        b.probe.clipboard_selection.len(),
        before,
        "selection changes must not be pushed to an unfocused data device"
    );
    focus(&mut b, &control, "focus-b-3", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("B missed focused offer")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"second-a"
    );

    // --- Primary selection is independent from the clipboard. ---
    focus(&mut a, &control, "focus-a-5", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let p_source = primary_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"primary-a")]),
    )?;
    primary_a.set_selection(Some(&p_source), serial_a);
    a.sync()?;
    focus(&mut b, &control, "focus-b-4", at(1))?;
    let p_offer = b
        .probe
        .primary_selection
        .last()
        .cloned()
        .flatten()
        .ok_or("B received no primary offer")?;
    assert_eq!(
        read_primary(&mut a, &mut b, &p_offer, "text/plain;charset=utf-8")?,
        b"primary-a"
    );
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("B lost clipboard offer")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?.as_slice(),
        b"second-a",
        "primary selection must not replace the clipboard"
    );

    // --- An open popup and a focus change must not disturb the selection. ---
    focus(&mut a, &control, "focus-a-popup", at(0))?;
    key_press(&control, "press-popup", "a")?;
    let popup_serial = wait_key(&mut a)?;
    let popup = a.popup(&a.window.xdg, (120, 80), (200, 180));
    popup
        .popup
        .grab(a.seat.as_ref().ok_or("missing seat")?, popup_serial);
    a.map_popup(&popup, 0xffffff00)?;
    let popup_surface = popup.surface.clone();
    wait_focus(&mut a, &popup_surface)?;
    // An outside click dismisses the popup; the root regains keyboard focus.
    click(&control, "popup-outside", at(1))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    while !a.probe.popup_done.contains(&popup.popup) {
        if Instant::now() >= deadline {
            return Err("popup was not dismissed by the outside click".into());
        }
        a.sync()?;
        thread::sleep(Duration::from_millis(10));
    }
    let root_surface = a.window.surface.clone();
    wait_focus(&mut a, &root_surface)?;
    popup.destroy();
    a.sync()?;
    focus(&mut b, &control, "focus-b-popup", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("offer after popup missing")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?.as_slice(),
        b"second-a",
        "popup grab/dismissal must preserve the selection owner"
    );

    // --- Empty selection: clearing is visible to the next focused client. ---
    focus(&mut a, &control, "focus-a-6", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    device_a.set_selection(None, serial_a);
    a.sync()?;
    let before = b.probe.clipboard_selection.len();
    focus(&mut b, &control, "focus-b-5", at(1))?;
    assert!(b.probe.clipboard_selection.len() > before);
    assert!(
        last_offer(&b.probe.clipboard_selection).is_none(),
        "cleared clipboard must be a null selection"
    );

    // --- Invalid and stale serials are rejected before Smithay applies them. ---
    focus(&mut a, &control, "focus-a-7", at(0))?;
    let stale = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let rejected = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"must-not-appear")]),
    )?;
    device_a.set_selection(Some(&rejected), stale.wrapping_add(0x5555_5555));
    a.sync()?;
    focus(&mut b, &control, "focus-b-6", at(1))?;
    assert!(
        last_offer(&b.probe.clipboard_selection).is_none(),
        "invalid serial selection must not be published"
    );
    // A valid serial still works.
    focus(&mut a, &control, "focus-a-8", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"valid-after-invalid")]),
    )?;
    device_a.set_selection(Some(&source), serial_a);
    a.sync()?;
    focus(&mut b, &control, "focus-b-7", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("valid selection missing")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"valid-after-invalid"
    );

    // A serial delivered before an intervening focus change is stale.
    focus(&mut a, &control, "focus-a-9", at(0))?;
    let old = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    focus(&mut b, &control, "focus-b-8", at(1))?;
    focus(&mut a, &control, "focus-a-10", at(0))?;
    let current = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let rejected = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"stale-not-applied")]),
    )?;
    device_a.set_selection(Some(&rejected), old);
    a.sync()?;
    device_a.set_selection(Some(&source), current);
    a.sync()?;
    focus(&mut b, &control, "focus-b-9", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("post-stale offer missing")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"valid-after-invalid",
        "the stale serial must not replace the current owner"
    );

    // --- Repeated data-device creation while focused is refreshed. ---
    let before = b.probe.clipboard_selection.len();
    device_b.release();
    let _new_device = clipboard_device(&b)?;
    b.sync()?;
    assert!(b.probe.clipboard_selection.len() > before);
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("recreated device got no offer")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"valid-after-invalid"
    );

    // --- Destroyed source is never offered or read again. ---
    focus(&mut a, &control, "focus-a-11", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let doomed = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"doomed")]),
    )?;
    device_a.set_selection(Some(&doomed), serial_a);
    a.sync()?;
    doomed.destroy();
    a.sync()?;
    let before = b.probe.clipboard_selection.len();
    focus(&mut b, &control, "focus-b-10", at(1))?;
    assert!(b.probe.clipboard_selection.len() > before);
    assert!(
        last_offer(&b.probe.clipboard_selection).is_none(),
        "a destroyed source must clear the selection"
    );

    // --- Bad fd and unknown MIME type do not reach the source or crash. ---
    focus(&mut a, &control, "focus-a-12", at(0))?;
    let serial_a = a.probe.keyboard_enter_serial.ok_or("no A enter serial")?;
    let source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"fd-safe")]),
    )?;
    device_a.set_selection(Some(&source), serial_a);
    a.sync()?;
    focus(&mut b, &control, "focus-b-11", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("fd offer missing")?;
    let sends = a.probe.source_sends.len();
    // Unknown type: Smithay drops the fd without contacting the source.
    let (read, write) = UnixStream::pair()?;
    offer.receive("application/x-not-offered".into(), write.as_fd());
    b.connection.flush()?;
    b.sync()?;
    drop(write);
    a.sync()?;
    assert_eq!(a.probe.source_sends.len(), sends);
    drop(read);
    // Receiver closes its read end before the source writes: EPIPE is contained.
    let (read, write) = UnixStream::pair()?;
    drop(read);
    offer.receive("text/plain;charset=utf-8".into(), write.as_fd());
    b.connection.flush()?;
    b.sync()?;
    drop(write);
    a.sync()?;
    assert_eq!(a.probe.source_send_errors, 1, "EPIPE must be counted");
    // The seat and compositor still transfer normally afterwards.
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"fd-safe"
    );

    // --- Unmap/remap with an active selection keeps ownership. ---
    focus(&mut a, &control, "focus-a-13", at(0))?;
    a.window.surface.attach(None, 0, 0);
    a.window.surface.commit();
    a.sync()?;
    a.window.surface.commit();
    a.sync()?;
    focus(&mut b, &control, "focus-b-12", at(1))?;
    let offer = last_offer(&b.probe.clipboard_selection).ok_or("offer after unmap missing")?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"fd-safe"
    );
    a.draw((320, 240))?;
    a.sync()?;
    focus(&mut a, &control, "focus-a-14", at(0))?;
    focus(&mut b, &control, "focus-b-13", at(1))?;
    assert_eq!(
        read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?,
        b"fd-safe",
        "remap must not disturb the selection owner"
    );

    // --- A receiver disconnecting with a live offer is harmless. ---
    let mut ephemeral = Peer::new(&socket, 0xff00ffff)?;
    let ephemeral_surface = ephemeral.window.surface.clone();
    wait_focus(&mut ephemeral, &ephemeral_surface)?;
    let _ephemeral_device = clipboard_device(&ephemeral)?;
    ephemeral.sync()?;
    assert!(last_offer(&ephemeral.probe.clipboard_selection).is_some());
    drop(ephemeral);
    a.sync()?;
    b.sync()?;

    // --- A source client disconnecting clears the selection. ---
    let mut c = Peer::new(&socket, 0xffff00ff)?;
    focus(&mut c, &control, "focus-c", at(2))?;
    let c_device = clipboard_device(&c)?;
    let serial_c = c.probe.keyboard_enter_serial.ok_or("no C enter serial")?;
    let c_source = clipboard_source(
        &c,
        SourceData::new(&[("text/plain;charset=utf-8", b"gone-with-client")]),
    )?;
    c_device.set_selection(Some(&c_source), serial_c);
    c.sync()?;
    drop(c);
    a.sync()?;
    focus(&mut b, &control, "focus-b-15", at(1))?;
    assert!(
        last_offer(&b.probe.clipboard_selection).is_none(),
        "a disconnected source must clear the selection"
    );

    // --- DnD remains delegated; an unvalidated serial is not started. ---
    focus(&mut a, &control, "focus-a-15", at(0))?;
    let drag_source =
        clipboard_source(&a, SourceData::new(&[("text/plain;charset=utf-8", b"dnd")]))?;
    let sends = a.probe.source_sends.len();
    device_a.start_drag(Some(&drag_source), &a.window.surface, None, 0xdead_beef_u32);
    a.sync()?;
    assert_eq!(
        a.probe.source_sends.len(),
        sends,
        "an invalid drag serial must not transfer data"
    );

    // --- Final health check after every teardown path. ---
    focus(&mut b, &control, "focus-b-14", at(1))?;
    b.sync()?;
    a.sync()?;
    fs::write(control.join("selection-done"), "ok")?;
    Ok(())
}
