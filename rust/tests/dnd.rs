//! Stage 4B protocol tests: negotiated client drag-and-drop with a rendered
//! icon, and compositor-driven popup constraint updates.
//!
//! Input is injected by one persistent virtual-pointer process per gesture, so
//! an implicit grab survives the whole press/move/release sequence. The Rust
//! test acts on real wire events while the driver holds the button.

use super::floating::Peer;
use super::selection::{
    at, clipboard_device, clipboard_source, focus, last_offer, mimes, read_clipboard, read_local,
    wait_focus, SourceData,
};
use super::*;
use std::{
    fs,
    os::fd::AsFd,
    path::Path,
    time::{Duration, Instant},
};
use wayland_client::protocol::{wl_data_device_manager::DndAction, wl_surface::WlSurface};

// ---------------------------------------------------------------------------
// Harness gates

#[cfg(feature = "winit")]
fn start_gate(control: &Path, name: &str, commands: &str) -> Result<()> {
    fs::write(control.join(format!("want-{name}")), commands)?;
    Ok(())
}

#[cfg(feature = "winit")]
fn wait_gate(control: &Path, name: &str) -> Result<()> {
    let done = control.join(format!("{name}-done"));
    let deadline = Instant::now() + Duration::from_secs(40);
    while !done.exists() {
        if Instant::now() >= deadline {
            return Err(format!("gate {name} timed out").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
    let reply = fs::read_to_string(&done)?;
    if reply.trim() == "ok" {
        Ok(())
    } else {
        Err(format!("gate {name} failed: {}", reply.trim()).into())
    }
}

#[cfg(feature = "winit")]
fn gate(control: &Path, name: &str, commands: &str) -> Result<()> {
    start_gate(control, name, commands)?;
    wait_gate(control, name)
}

#[cfg(feature = "winit")]
fn shot(control: &Path, name: &str, specs: &str) -> Result<()> {
    fs::write(control.join(format!("want-shot-{name}")), specs)?;
    let done = control.join(format!("shot-{name}-done"));
    let deadline = Instant::now() + Duration::from_secs(30);
    while !done.exists() {
        if Instant::now() >= deadline {
            return Err(format!("screenshot {name} timed out").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
    let reply = fs::read_to_string(&done)?;
    if reply.trim() == "ok" {
        Ok(())
    } else {
        Err(format!("screenshot {name} failed: {}", reply.trim()).into())
    }
}

#[cfg(feature = "winit")]
fn poll_until(
    peer: &mut Peer,
    label: &str,
    timeout: Duration,
    mut predicate: impl FnMut(&Probe) -> bool,
) -> Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        peer.sync()?;
        if predicate(&peer.probe) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("timed out waiting for {label}").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

// ---------------------------------------------------------------------------
// Input and icon helpers

#[cfg(feature = "winit")]
fn wait_press(peer: &mut Peer, since: usize) -> Result<u32> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        peer.sync()?;
        if let Some((serial, _)) = peer.probe.input_serials[since..]
            .iter()
            .rev()
            .find(|(_, state)| *state == WEnum::Value(wl_pointer::ButtonState::Pressed))
        {
            return Ok(*serial);
        }
        if Instant::now() >= deadline {
            return Err("client did not receive the pointer press".into());
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[cfg(feature = "winit")]
struct Icon {
    surface: WlSurface,
    #[allow(dead_code)]
    buffer: wl_buffer::WlBuffer,
}

#[cfg(feature = "winit")]
fn render_barrier(peer: &mut Peer) -> Result<()> {
    let frames = peer.probe.frames;
    peer.window
        .surface
        .frame(&peer.queue.handle(), Callback::Frame);
    peer.window.surface.commit();
    poll_until(peer, "render barrier", Duration::from_secs(10), |probe| {
        probe.frames > frames
    })
}

#[cfg(feature = "winit")]
fn new_icon(peer: &Peer, color: u32, scale: i32, offset: (i32, i32)) -> Result<Icon> {
    let size = 32 * scale;
    let surface = peer.compositor.create_surface(&peer.queue.handle(), ());
    let buffer = peer.buffer((size, size), color)?;
    if scale != 1 {
        surface.set_buffer_scale(scale);
    }
    surface.attach(Some(&buffer), offset.0, offset.1);
    surface.damage_buffer(0, 0, size, size);
    surface.commit();
    Ok(Icon { surface, buffer })
}

#[cfg(feature = "winit")]
fn last_dnd_offer(peer: &Peer) -> Option<(u32, WlSurface, wl_data_offer::WlDataOffer, f64, f64)> {
    peer.probe
        .dnd_enters
        .last()
        .and_then(|(serial, surface, id, x, y)| {
            id.as_ref()
                .map(|offer| (*serial, surface.clone(), offer.clone(), *x, *y))
        })
}

#[cfg(feature = "winit")]
fn action(value: WEnum<DndAction>) -> Option<DndAction> {
    match value {
        WEnum::Value(action) => Some(action),
        WEnum::Unknown(_) => None,
    }
}

#[cfg(feature = "winit")]
fn actions(peer: &Probe, offer: &wl_data_offer::WlDataOffer) -> DndAction {
    peer.offer_source_actions
        .iter()
        .find(|(known, _)| known == offer)
        .and_then(|(_, value)| action(*value))
        .unwrap_or(DndAction::None)
}

#[cfg(feature = "winit")]
fn source_action(peer: &Peer, wanted: DndAction) -> bool {
    peer.probe
        .source_actions
        .iter()
        .any(|value| action(*value) == Some(wanted))
}

#[cfg(feature = "winit")]
fn popup_geometry(
    peer: &Peer,
    popup: &wayland_protocols::xdg::shell::client::xdg_popup::XdgPopup,
) -> Option<(i32, i32, i32, i32)> {
    peer.probe
        .popup_geometry
        .iter()
        .rev()
        .find(|(known, _)| known == popup)
        .map(|(_, geometry)| *geometry)
}

#[cfg(feature = "winit")]
fn wait_popup_geometry(
    peer: &mut Peer,
    popup: &wayland_protocols::xdg::shell::client::xdg_popup::XdgPopup,
    previous: Option<(i32, i32, i32, i32)>,
    label: &str,
) -> Result<(i32, i32, i32, i32)> {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        peer.sync()?;
        let geometry = popup_geometry(peer, popup);
        if geometry.is_some() && geometry != previous {
            return Ok(geometry.ok_or("missing popup geometry")?);
        }
        if Instant::now() >= deadline {
            return Err(format!("popup did not reconfigure after {label}").into());
        }
        thread::sleep(Duration::from_millis(10));
    }
}

// ---------------------------------------------------------------------------
// Tests

#[test]
#[cfg(feature = "winit")]
#[ignore = "requires stage4b-smoke.py private graphical parent and input driver"]
fn dnd_icon_targets_actions_and_teardown() -> Result<()> {
    let socket = PathBuf::from(std::env::var_os("RAYWM_SMOKE_SOCKET").ok_or("run harness")?);
    let control = PathBuf::from(std::env::var_os("RAYWM_SMOKE_CONTROL").ok_or("run harness")?);
    let mut a = Peer::new(&socket, 0xffff0000)?;
    let mut b = Peer::new(&socket, 0xff00ff00)?;
    let b_surface = b.window.surface.clone();
    wait_focus(&mut b, &b_surface)?;
    let device_a = clipboard_device(&a)?;
    let _device_b = clipboard_device(&b)?;
    a.sync()?;
    b.sync()?;
    focus(&mut a, &control, "dnd-focus-a", at(0))?;

    // A forged serial cannot start a drag: Smithay requires the current held
    // implicit pointer grab. No source, icon, enter or drop may appear.
    let rejected = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"forged")]),
    )?;
    device_a.start_drag(Some(&rejected), &a.window.surface, None, 0xdead_beef);
    a.sync()?;
    b.sync()?;
    assert!(b.probe.dnd_enters.is_empty());
    rejected.destroy();

    // One persistent driver holds the button for the full gesture. The test
    // starts the protocol drag while the driver sleeps after `down`.
    start_gate(
        &control,
        "dnd-main",
        "move 20 20 down left sleep 2500 move 120 120 sleep 500 move 340 68 sleep 600 \
         move 120 120 sleep 500 move 340 68 sleep 6000 up left sleep 500",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;

    // Clipboard and DnD are independent sources on the same seat.
    let clipboard = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"clip-during-dnd")]),
    )?;
    device_a.set_selection(Some(&clipboard), serial);
    a.sync()?;
    let clip_offer = last_offer(&a.probe.clipboard_selection).ok_or("no self clipboard offer")?;

    let icon = new_icon(&a, 0xffffff00, 1, (0, 0))?;
    let source = clipboard_source(
        &a,
        SourceData::new(&[
            ("text/plain;charset=utf-8", b"dnd-payload"),
            ("text/plain", b"dnd-plain"),
        ]),
    )?;
    source.set_actions(DndAction::Copy | DndAction::Move | DndAction::Ask);
    device_a.start_drag(
        Some(&source),
        &a.window.surface,
        Some(&icon.surface),
        serial,
    );
    a.connection.flush()?;

    poll_until(&mut b, "target switch", Duration::from_secs(20), |probe| {
        probe.dnd_enters.len() == 2
    })?;
    assert_eq!(b.probe.dnd_leaves, 1);
    let (enter_serial, surface, offer, x, y) = last_dnd_offer(&b).ok_or("no DnD offer on B")?;
    assert_eq!(surface, b_surface);
    assert!(x > 0.0 && y > 0.0);
    assert_eq!(
        mimes(&b.probe, &offer),
        ["text/plain", "text/plain;charset=utf-8"]
    );
    for action in [DndAction::Copy, DndAction::Move, DndAction::Ask] {
        assert!(actions(&b.probe, &offer).contains(action));
    }

    // The icon is composited above B; clipboard data still flows while the
    // DnD grab is active.
    render_barrier(&mut a)?;
    shot(&control, "dnd-icon", "356,84,ffff00")?;
    let clip = read_local(&mut a, &clip_offer, "text/plain;charset=utf-8")?;
    assert_eq!(clip, b"clip-during-dnd");

    offer.accept(enter_serial, Some("text/plain;charset=utf-8".into()));
    offer.set_actions(
        DndAction::Copy | DndAction::Move | DndAction::Ask,
        DndAction::Ask,
    );
    b.connection.flush()?;
    b.sync()?;
    a.sync()?;
    assert!(source_action(&a, DndAction::Ask));
    assert_eq!(
        action(
            b.probe
                .offer_actions
                .iter()
                .find(|(known, _)| known == &offer)
                .map(|(_, value)| *value)
                .ok_or("no action event")?
        ),
        Some(DndAction::Ask)
    );

    // Closed receiver pipe is contained by the source client.
    let (read, write) = UnixStream::pair()?;
    drop(read);
    let errors = a.probe.source_send_errors;
    offer.receive("text/plain;charset=utf-8".into(), write.as_fd());
    b.connection.flush()?;
    b.sync()?;
    drop(write);
    a.sync()?;
    assert_eq!(a.probe.source_send_errors, errors + 1);

    let data = read_clipboard(&mut a, &mut b, &offer, "text/plain;charset=utf-8")?;
    assert_eq!(data, b"dnd-payload");

    poll_until(&mut b, "drop", Duration::from_secs(20), |probe| {
        probe.dnd_drops == 1
    })?;
    a.sync()?;
    assert_eq!(a.probe.source_drop_performed, 1);
    offer.finish();
    b.connection.flush()?;
    b.sync()?;
    a.sync()?;
    assert_eq!(a.probe.source_finished, 1);
    b.sync()?;
    a.sync()?;
    assert_eq!(b.probe.dnd_drops, 1);
    assert_eq!(a.probe.source_finished, 1);
    wait_gate(&control, "dnd-main")?;
    render_barrier(&mut a)?;
    shot(&control, "dnd-icon-gone", "330,80,00ff00")?;

    // Cancelled drag: no target accept means no drop, source cancelled.
    start_gate(
        &control,
        "dnd-cancel",
        "move 20 20 down left sleep 2000 move 340 68 sleep 2500 up left sleep 400",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    let cancel_icon = new_icon(&a, 0xff00ffff, 1, (0, 0))?;
    let cancel_source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"cancel")]),
    )?;
    cancel_source.set_actions(DndAction::Copy);
    let enters = b.probe.dnd_enters.len();
    device_a.start_drag(
        Some(&cancel_source),
        &a.window.surface,
        Some(&cancel_icon.surface),
        serial,
    );
    a.connection.flush()?;
    poll_until(&mut b, "cancel enter", Duration::from_secs(15), |probe| {
        probe.dnd_enters.len() > enters
    })?;
    poll_until(&mut a, "source cancel", Duration::from_secs(20), |probe| {
        probe.source_cancelled >= 1
    })?;
    assert_eq!(b.probe.dnd_drops, 1);
    assert_eq!(a.probe.source_drop_performed, 1);
    wait_gate(&control, "dnd-cancel")?;
    render_barrier(&mut a)?;
    shot(&control, "dnd-cancel-gone", "330,80,00ff00")?;

    // Unoffered MIME acceptance is not a valid drop.
    start_gate(
        &control,
        "dnd-badmime",
        "move 20 20 down left sleep 2000 move 340 68 sleep 3000 up left sleep 400",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    let bad_icon = new_icon(&a, 0xff00ff00, 1, (0, 0))?;
    let bad_source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"badmime")]),
    )?;
    bad_source.set_actions(DndAction::Copy);
    let enters = b.probe.dnd_enters.len();
    device_a.start_drag(
        Some(&bad_source),
        &a.window.surface,
        Some(&bad_icon.surface),
        serial,
    );
    a.connection.flush()?;
    poll_until(&mut b, "bad MIME enter", Duration::from_secs(15), |probe| {
        probe.dnd_enters.len() > enters
    })?;
    let (serial, _, bad_offer, _, _) = last_dnd_offer(&b).ok_or("no bad MIME offer")?;
    bad_offer.accept(serial, Some("application/x-unoffered".into()));
    bad_offer.set_actions(DndAction::Copy, DndAction::Copy);
    b.connection.flush()?;
    poll_until(
        &mut a,
        "bad MIME cancel",
        Duration::from_secs(20),
        |probe| probe.source_cancelled >= 2,
    )?;
    assert_eq!(b.probe.dnd_drops, 1);
    wait_gate(&control, "dnd-badmime")?;

    // Move action and a buffer-scale-2 icon (64x64 buffer, 32x32 logical).
    start_gate(
        &control,
        "dnd-move",
        "move 20 20 down left sleep 2000 move 340 68 sleep 5000 up left sleep 400",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    let offset_icon = new_icon(&a, 0xffffff00, 2, (0, 0))?;
    let move_source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"move-payload")]),
    )?;
    move_source.set_actions(DndAction::Copy | DndAction::Move);
    let enters = b.probe.dnd_enters.len();
    device_a.start_drag(
        Some(&move_source),
        &a.window.surface,
        Some(&offset_icon.surface),
        serial,
    );
    a.connection.flush()?;
    poll_until(&mut b, "move enter", Duration::from_secs(15), |probe| {
        probe.dnd_enters.len() > enters
    })?;
    let (serial, _, move_offer, _, _) = last_dnd_offer(&b).ok_or("no move offer")?;
    move_offer.accept(serial, Some("text/plain;charset=utf-8".into()));
    move_offer.set_actions(DndAction::Copy | DndAction::Move, DndAction::Move);
    b.connection.flush()?;
    b.sync()?;
    a.sync()?;
    assert!(source_action(&a, DndAction::Move));
    render_barrier(&mut a)?;
    shot(&control, "dnd-icon-offset", "356,84,ffff00;330,80,00ff00")?;
    poll_until(&mut b, "move drop", Duration::from_secs(20), |probe| {
        probe.dnd_drops == 2
    })?;
    move_offer.finish();
    b.connection.flush()?;
    b.sync()?;
    a.sync()?;
    assert_eq!(a.probe.source_finished, 2);
    wait_gate(&control, "dnd-move")?;

    // Icon surface destroyed mid-drag: overlay disappears, drag still ends.
    start_gate(
        &control,
        "dnd-icon-destroy",
        "move 20 20 down left sleep 2000 move 340 68 sleep 3000 up left sleep 400",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    let dying_icon = new_icon(&a, 0xff00ffff, 1, (0, 0))?;
    let dying_source = clipboard_source(
        &a,
        SourceData::new(&[("text/plain;charset=utf-8", b"icon-gone")]),
    )?;
    dying_source.set_actions(DndAction::Copy);
    let enters = b.probe.dnd_enters.len();
    device_a.start_drag(
        Some(&dying_source),
        &a.window.surface,
        Some(&dying_icon.surface),
        serial,
    );
    a.connection.flush()?;
    poll_until(&mut b, "destroy enter", Duration::from_secs(15), |probe| {
        probe.dnd_enters.len() > enters
    })?;
    dying_icon.surface.destroy();
    a.sync()?;
    render_barrier(&mut a)?;
    shot(&control, "dnd-destroyed-icon", "356,84,00ff00")?;
    wait_gate(&control, "dnd-icon-destroy")?;
    b.sync()?;
    a.sync()?;

    // Source client disconnect mid-drag: target survives, no fake drop.
    let mut source_peer = Peer::new(&socket, 0xffff00ff)?;
    focus(&mut source_peer, &control, "dnd-focus-c", at(2))?;
    start_gate(
        &control,
        "dnd-source-disconnect",
        "move 388 116 down left sleep 2500 move 340 68 sleep 3500 up left sleep 400",
    )?;
    let since = source_peer.probe.input_serials.len();
    let serial = wait_press(&mut source_peer, since)?;
    let c_icon = new_icon(&source_peer, 0xffffff00, 1, (0, 0))?;
    let c_source = clipboard_source(
        &source_peer,
        SourceData::new(&[("text/plain;charset=utf-8", b"disconnect")]),
    )?;
    c_source.set_actions(DndAction::Copy);
    let c_device = clipboard_device(&source_peer)?;
    b.sync()?;
    let previous_offer = last_dnd_offer(&b).map(|(_, _, offer, _, _)| offer);
    let enters = b.probe.dnd_enters.len();
    c_device.start_drag(
        Some(&c_source),
        &source_peer.window.surface,
        Some(&c_icon.surface),
        serial,
    );
    source_peer.sync()?;
    poll_until(
        &mut b,
        "disconnect enter",
        Duration::from_secs(15),
        |probe| {
            probe.dnd_enters.len() > enters
                && probe
                    .dnd_enters
                    .last()
                    .is_some_and(|(_, _, offer, _, _)| offer.as_ref() != previous_offer.as_ref())
        },
    )?;
    let leaves = b.probe.dnd_leaves;
    drop(source_peer);
    wait_gate(&control, "dnd-source-disconnect")?;
    poll_until(
        &mut b,
        "disconnect leave",
        Duration::from_secs(15),
        |probe| probe.dnd_leaves > leaves,
    )?;
    assert_eq!(
        b.probe.dnd_drops, 2,
        "a source disconnect must not fake a drop"
    );
    shot(&control, "dnd-source-disconnect-gone", "356,84,00ff00")?;

    // A fresh source still drags to the surviving target.
    let mut c = Peer::new(&socket, 0xff00ffff)?;
    focus(&mut c, &control, "dnd-focus-d", at(2))?;
    start_gate(
        &control,
        "dnd-recover",
        "move 388 116 down left sleep 2500 move 340 68 sleep 5000 up left sleep 400",
    )?;
    let since = c.probe.input_serials.len();
    let serial = wait_press(&mut c, since)?;
    let d_icon = new_icon(&c, 0xffffff00, 1, (0, 0))?;
    let d_source = clipboard_source(
        &c,
        SourceData::new(&[("text/plain;charset=utf-8", b"after-disconnect")]),
    )?;
    d_source.set_actions(DndAction::Copy);
    let d_device = clipboard_device(&c)?;
    let enters = b.probe.dnd_enters.len();
    d_device.start_drag(
        Some(&d_source),
        &c.window.surface,
        Some(&d_icon.surface),
        serial,
    );
    c.connection.flush()?;
    poll_until(&mut b, "recovery enter", Duration::from_secs(15), |probe| {
        probe.dnd_enters.len() > enters
    })?;
    let (serial, _, offer, _, _) = last_dnd_offer(&b).ok_or("no recovery offer")?;
    offer.accept(serial, Some("text/plain;charset=utf-8".into()));
    offer.set_actions(DndAction::Copy, DndAction::Copy);
    b.connection.flush()?;
    b.sync()?;
    let data = read_clipboard(&mut c, &mut b, &offer, "text/plain;charset=utf-8")?;
    assert_eq!(data, b"after-disconnect");
    poll_until(&mut b, "recovery drop", Duration::from_secs(20), |probe| {
        probe.dnd_drops == 3
    })?;
    offer.finish();
    b.connection.flush()?;
    c.sync()?;
    wait_gate(&control, "dnd-recover")?;

    // A serial from the completed drag is stale.
    let enters = b.probe.dnd_enters.len();
    start_gate(&control, "dnd-stale", "sleep 1")?;
    wait_gate(&control, "dnd-stale")?;
    let stale = serial;
    let stale_source = clipboard_source(
        &c,
        SourceData::new(&[("text/plain;charset=utf-8", b"stale")]),
    )?;
    d_device.start_drag(Some(&stale_source), &c.window.surface, None, stale);
    c.sync()?;
    b.sync()?;
    assert_eq!(b.probe.dnd_enters.len(), enters);

    fs::write(control.join("dnd-done"), "ok")?;
    Ok(())
}

#[test]
#[cfg(feature = "winit")]
#[ignore = "requires stage4b-smoke.py private graphical parent and input driver"]
fn reactive_popup_constraints_and_lifecycle() -> Result<()> {
    let socket = PathBuf::from(std::env::var_os("RAYWM_SMOKE_SOCKET").ok_or("run harness")?);
    let control = PathBuf::from(std::env::var_os("RAYWM_SMOKE_CONTROL").ok_or("run harness")?);
    let mut a = Peer::new(&socket, 0xffff0000)?;
    let a_surface = a.window.surface.clone();
    wait_focus(&mut a, &a_surface)?;
    let seat = a.seat.clone().ok_or("missing seat")?;

    let popup = a.popup(&a.window.xdg, (120, 80), (200, 180));
    a.map_popup(&popup, 0xffffff00)?;
    let initial = popup_geometry(&a, &popup.popup).ok_or("missing initial popup geometry")?;
    assert_eq!(initial, (201, 181, 120, 80));
    // A large nested popup is anchored near the parent popup's edge. It must
    // be constrained whenever the root/popup position or output changes.
    let child = a.popup(&popup.xdg, (180, 140), (100, 60));
    a.map_popup(&child, 0xffff00ff)?;
    let child_initial = popup_geometry(&a, &child.popup).ok_or("missing child geometry")?;
    assert_eq!(child_initial, (101, 61, 180, 140));

    // Move the parent with a real pointer grab; the popup must be constrained
    // back into the output after the move, with one or more real configures.
    start_gate(
        &control,
        "popup-move",
        "move 20 20 down left sleep 2000 move 560 410 sleep 800 up left sleep 300",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    a.window.top._move(&seat, serial);
    a.connection.flush()?;
    let moved = wait_popup_geometry(&mut a, &popup.popup, Some(initial), "parent move")?;
    assert_ne!(moved, initial);
    // Popup configure coordinates are relative to the parent window geometry;
    // the parent moved to (540,390), so check the resulting screen rectangle.
    let parent = (540, 390);
    assert!(parent.0 + moved.0 + moved.2 <= 800 && parent.1 + moved.1 + moved.3 <= 600);
    a.ack(&popup.xdg)?;
    popup.surface.commit();
    a.sync()?;
    let child_moved =
        wait_popup_geometry(&mut a, &child.popup, Some(child_initial), "nested move")?;
    assert!(parent.0 + moved.0 + child_moved.0 + child_moved.2 <= 800);
    assert!(parent.1 + moved.1 + child_moved.1 + child_moved.3 <= 600);
    a.ack(&child.xdg)?;
    child.surface.commit();
    a.sync()?;
    wait_gate(&control, "popup-move")?;

    // Output resize re-constrains the same popup into 700x500.
    gate(
        &control,
        "popup-output",
        "parent key super down key f9 down key f9 up key super up sleep 600",
    )?;
    let resized = wait_popup_geometry(&mut a, &popup.popup, Some(moved), "output resize")?;
    assert!(parent.0 + resized.0 + resized.2 <= 700);
    assert!(parent.1 + resized.1 + resized.3 <= 500);
    a.ack(&popup.xdg)?;
    popup.surface.commit();
    a.sync()?;
    // With the parent popup's new constrained position the child's own
    // constraint result is unchanged, so no second configure is required.
    a.sync()?;
    let child_resized = popup_geometry(&a, &child.popup).ok_or("missing child after resize")?;
    assert!(parent.0 + resized.0 + child_resized.0 + child_resized.2 <= 700);
    assert!(parent.1 + resized.1 + child_resized.1 + child_resized.3 <= 500);

    // The nested popup follows its parent popup after the toplevel moves back.
    start_gate(
        &control,
        "popup-move-back",
        "move 560 410 down left sleep 2000 move 60 60 sleep 800 up left sleep 300",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    a.window.top._move(&seat, serial);
    a.connection.flush()?;
    let back = wait_popup_geometry(&mut a, &popup.popup, Some(resized), "parent move back")?;
    let parent = (40, 40);
    assert!(parent.0 + back.0 + back.2 <= 700 && parent.1 + back.1 + back.3 <= 500);
    a.ack(&popup.xdg)?;
    popup.surface.commit();
    a.sync()?;
    let child_back =
        wait_popup_geometry(&mut a, &child.popup, Some(child_resized), "nested follow")?;
    // The child configure is relative to the parent popup.
    assert!(parent.0 + back.0 + child_back.0 + child_back.2 <= 700);
    assert!(parent.1 + back.1 + child_back.1 + child_back.3 <= 500);
    a.ack(&child.xdg)?;
    child.surface.commit();
    a.sync()?;
    shot(
        &control,
        "popup-child",
        &format!(
            "{},{},ff00ff",
            parent.0 + back.0 + child_back.0 + child_back.2 / 2,
            parent.1 + back.1 + child_back.1 + child_back.3 / 2
        ),
    )?;
    wait_gate(&control, "popup-move-back")?;

    // Bottom-right resize does not invalidate the relative popup anchor and
    // must not produce unbounded configure traffic.
    start_gate(
        &control,
        "popup-resize",
        "move 60 60 down left sleep 2000 move 200 200 sleep 800 up left sleep 300",
    )?;
    let since = a.probe.input_serials.len();
    let serial = wait_press(&mut a, since)?;
    a.window
        .top
        .resize(&seat, serial, xdg_toplevel::ResizeEdge::BottomRight);
    a.connection.flush()?;
    let before = popup_geometry(&a, &popup.popup);
    wait_gate(&control, "popup-resize")?;
    a.sync()?;
    assert_eq!(
        before,
        popup_geometry(&a, &popup.popup),
        "a valid popup must not be reconfigured without a geometry change"
    );
    a.draw(a.size)?;
    a.sync()?;

    // A valid reposition token changes the popup position.
    let reposition = a.positioner((120, 80), (40, 40));
    popup.popup.reposition(&reposition, 4242);
    reposition.destroy();
    a.sync()?;
    assert!(a.probe.repositioned.contains(&4242));
    let repositioned = wait_popup_geometry(&mut a, &popup.popup, Some(back), "reposition request")?;
    assert!(repositioned.0 + repositioned.2 <= 700 && repositioned.1 + repositioned.3 <= 700);
    a.ack(&popup.xdg)?;
    popup.surface.commit();
    a.sync()?;

    // Parent unmap dismisses both popups exactly once.
    a.window.surface.attach(None, 0, 0);
    a.window.surface.commit();
    a.sync()?;
    assert!(a.probe.popup_done.contains(&popup.popup));
    assert!(a.probe.popup_done.contains(&child.popup));
    child.destroy();
    popup.destroy();
    a.window.surface.commit();
    a.sync()?;
    a.draw((300, 200))?;
    a.sync()?;
    let remapped = a.popup(&a.window.xdg, (100, 70), (40, 40));
    a.map_popup(&remapped, 0xffffff00)?;
    let remapped_geometry = popup_geometry(&a, &remapped.popup).ok_or("no popup after remap")?;
    assert!(parent.0 + remapped_geometry.0 + remapped_geometry.2 <= 800);
    remapped.surface.attach(None, 0, 0);
    remapped.surface.commit();
    a.sync()?;
    remapped.destroy();

    // Destroy a parent while its new popup's initial configure is unACKed.
    let doomed = a.popup(&a.window.xdg, (80, 60), (20, 20));
    doomed.surface.commit();
    a.sync()?;
    a.destroy();
    a.sync()?;
    let mut survivor = Peer::new(&socket, 0xff00ffff)?;
    let survivor_surface = survivor.window.surface.clone();
    wait_focus(&mut survivor, &survivor_surface)?;
    survivor.draw((280, 180))?;
    survivor.sync()?;

    fs::write(control.join("popup-done"), "ok")?;
    Ok(())
}
