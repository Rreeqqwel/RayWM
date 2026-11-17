//! Real wire requests with an in-process compositor, so internal commands and
//! both core/Space state can be observed without adding a test IPC protocol.
use crate::{
    state::{ClientState, State},
    Result,
};
use raywm_core::{
    commands::{Command as C, CommandError, Event},
    windows::{Geometry, OutputId, Position, Size},
};
use smithay::reexports::wayland_server::Display;
use std::{
    io::Write,
    os::{fd::AsFd, unix::net::UnixStream},
    sync::Arc,
};
use wayland_client::{
    delegate_noop,
    protocol::{
        wl_buffer, wl_callback, wl_compositor, wl_registry, wl_shm, wl_shm_pool, wl_surface,
    },
    Connection, Dispatch, EventQueue, QueueHandle,
};
use wayland_protocols::xdg::shell::client::{
    xdg_popup, xdg_positioner, xdg_surface, xdg_toplevel, xdg_wm_base,
};

#[derive(Default)]
struct Probe {
    globals: Vec<(u32, String, u32)>,
    configures: Vec<(xdg_surface::XdgSurface, u32)>,
    closes: usize,
    popup_done: usize,
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
            state.configures.push((surface.clone(), serial));
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
        if matches!(event, xdg_toplevel::Event::Close) {
            state.closes += 1;
        }
    }
}
delegate_noop!(Probe: ignore wl_callback::WlCallback);
delegate_noop!(Probe: ignore wl_compositor::WlCompositor);
delegate_noop!(Probe: ignore wl_shm::WlShm);
delegate_noop!(Probe: ignore wl_shm_pool::WlShmPool);
delegate_noop!(Probe: ignore wl_buffer::WlBuffer);
delegate_noop!(Probe: ignore wl_surface::WlSurface);
delegate_noop!(Probe: ignore xdg_wm_base::XdgWmBase);
delegate_noop!(Probe: ignore xdg_positioner::XdgPositioner);
impl Dispatch<xdg_popup::XdgPopup, ()> for Probe {
    fn event(
        state: &mut Self,
        _: &xdg_popup::XdgPopup,
        event: xdg_popup::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if matches!(event, xdg_popup::Event::PopupDone) {
            state.popup_done += 1;
        }
    }
}

struct Harness {
    display: Display<State>,
    state: State,
    client: Connection,
    queue: EventQueue<Probe>,
    probe: Probe,
}
struct Window {
    surface: wl_surface::WlSurface,
    xdg: xdg_surface::XdgSurface,
    top: xdg_toplevel::XdgToplevel,
}
impl Harness {
    fn new() -> Result<Self> {
        let display = Display::new()?;
        let state = State::new(&display.handle());
        let (server, client) = UnixStream::pair()?;
        display
            .handle()
            .insert_client(server, Arc::new(ClientState::default()))?;
        let client = Connection::from_socket(client)?;
        let queue = client.new_event_queue();
        client.display().get_registry(&queue.handle(), ());
        let mut harness = Self {
            display,
            state,
            client,
            queue,
            probe: Probe::default(),
        };
        harness.pump()?;
        Ok(harness)
    }
    fn pump(&mut self) -> Result<()> {
        // A sync callback guarantees input for the bounded read even if no
        // state/configure changed. All requests preceding it are dispatched.
        self.client.display().sync(&self.queue.handle(), ());
        self.client.flush()?;
        self.display.dispatch_clients(&mut self.state)?;
        self.state.flush_geometry();
        self.display.flush_clients()?;
        if let Some(guard) = self.queue.prepare_read() {
            use rustix::event::{poll, PollFd, PollFlags, Timespec};
            let mut fds = [PollFd::new(&self.client, PollFlags::IN)];
            if poll(
                &mut fds,
                Some(&Timespec {
                    tv_sec: 3,
                    tv_nsec: 0,
                }),
            )? == 0
            {
                return Err("wire timeout".into());
            }
            guard.read()?;
        }
        self.queue.dispatch_pending(&mut self.probe)?;
        Ok(())
    }
    fn global(&self, name: &str) -> Result<(u32, u32)> {
        self.probe
            .globals
            .iter()
            .find(|(_, interface, _)| interface == name)
            .map(|(id, _, v)| (*id, *v))
            .ok_or_else(|| format!("missing {name}").into())
    }
    fn window(&mut self) -> Result<Window> {
        let qh = self.queue.handle();
        let registry = self.client.display().get_registry(&qh, ());
        let (id, v) = self.global("wl_compositor")?;
        let compositor: wl_compositor::WlCompositor = registry.bind(id, v.min(6), &qh, ());
        let (id, v) = self.global("xdg_wm_base")?;
        let shell: xdg_wm_base::XdgWmBase = registry.bind(id, v.min(6), &qh, ());
        let surface = compositor.create_surface(&qh, ());
        let xdg = shell.get_xdg_surface(&surface, &qh, ());
        let top = xdg.get_toplevel(&qh, ());
        surface.commit();
        self.pump()?;
        let window = Window { surface, xdg, top };
        self.ack(&window)?;
        self.draw(&window, 320, 200)?;
        Ok(window)
    }
    fn ack(&self, window: &Window) -> Result<()> {
        let serial = self
            .probe
            .configures
            .iter()
            .rev()
            .find(|(surface, _)| surface == &window.xdg)
            .map(|(_, serial)| *serial)
            .ok_or("no configure")?;
        window.xdg.ack_configure(serial);
        Ok(())
    }
    fn draw(&mut self, window: &Window, w: i32, h: i32) -> Result<()> {
        self.draw_surface(&window.surface, w, h)
    }
    fn draw_surface(&mut self, surface: &wl_surface::WlSurface, w: i32, h: i32) -> Result<()> {
        let qh = self.queue.handle();
        let registry = self.client.display().get_registry(&qh, ());
        let (id, _) = self.global("wl_shm")?;
        let shm: wl_shm::WlShm = registry.bind(id, 1, &qh, ());
        let mut file = tempfile::tempfile()?;
        file.write_all(&vec![255; (w * h * 4) as usize])?;
        let pool = shm.create_pool(file.as_fd(), w * h * 4, &qh, ());
        let buffer = pool.create_buffer(0, w, h, w * 4, wl_shm::Format::Argb8888, &qh, ());
        pool.destroy();
        surface.attach(Some(&buffer), 0, 0);
        surface.commit();
        self.pump()
    }
}

#[test]
fn hiding_workspace_dismisses_wire_popup_without_creating_managed_window() -> Result<()> {
    let mut h = Harness::new()?;
    let parent = h.window()?;
    let qh = h.queue.handle();
    let registry = h.client.display().get_registry(&qh, ());
    let (id, v) = h.global("wl_compositor")?;
    let compositor: wl_compositor::WlCompositor = registry.bind(id, v.min(6), &qh, ());
    let (id, v) = h.global("xdg_wm_base")?;
    let shell: xdg_wm_base::XdgWmBase = registry.bind(id, v.min(6), &qh, ());
    let positioner = shell.create_positioner(&qh, ());
    positioner.set_size(60, 40);
    positioner.set_anchor_rect(10, 10, 20, 20);
    let surface = compositor.create_surface(&qh, ());
    let xdg = shell.get_xdg_surface(&surface, &qh, ());
    let popup = xdg.get_popup(Some(&parent.xdg), &positioner, &qh, ());
    surface.commit();
    h.pump()?;
    let serial = h
        .probe
        .configures
        .iter()
        .rev()
        .find(|(s, _)| s == &xdg)
        .map(|(_, serial)| *serial)
        .ok_or("popup configure")?;
    xdg.ack_configure(serial);
    h.draw_surface(&surface, 60, 40)?;
    assert_eq!(h.state.views.len(), 1);
    assert_eq!(h.state.desktop.windows().count(), 1);
    assert_eq!(h.state.popup_entries.len(), 1);
    let workspace = h.state.execute_command(C::CreateWorkspace)?;
    let workspace = match workspace.events.as_slice() {
        [Event::WorkspaceCreated(id)] => *id,
        _ => return Err("workspace".into()),
    };
    h.state.execute_command(C::ActivateWorkspace(workspace))?;
    h.pump()?;
    assert_eq!(h.probe.popup_done, 1);
    assert_eq!(h.state.space.elements().count(), 0);
    assert_eq!(h.state.desktop.focused(), None);
    popup.destroy();
    xdg.destroy();
    surface.destroy();
    h.pump()?;
    assert!(h.state.popup_entries.is_empty());
    Ok(())
}

#[test]
fn workspace_commands_reconcile_real_surfaces_space_and_lifecycle() -> Result<()> {
    let mut h = Harness::new()?;
    h.state.host_focused = true;
    let a = h.window()?;
    let b = h.window()?;
    let a_id = h.state.views[0].id;
    let b_id = h.state.views[1].id;
    assert_eq!(h.state.space.elements().count(), 2);
    let first = h.state.desktop.active_workspace();
    let created = h.state.execute_command(C::CreateWorkspace)?;
    let second = match created.events.as_slice() {
        [Event::WorkspaceCreated(id)] => *id,
        _ => return Err("missing event".into()),
    };
    h.state.execute_command(C::MoveWindowToWorkspace {
        id: b_id,
        workspace: second,
    })?;
    assert_eq!(h.state.space.elements().count(), 1);
    assert_eq!(h.state.desktop.focused(), Some(a_id));
    assert!(h.state.desktop.get(b_id).ok_or("b")?.mapped());
    h.state.execute_command(C::ActivateWorkspace(second))?;
    assert_eq!(h.state.desktop.focused(), Some(b_id));
    assert_eq!(h.state.space.elements().count(), 1);
    assert!(h
        .state
        .space
        .element_location(&h.state.views[0].window)
        .is_none());
    h.state.execute_command(C::MoveWindow {
        id: b_id,
        position: Position { x: 91, y: 73 },
    })?;
    assert_eq!(
        h.state.space.element_location(&h.state.views[1].window),
        Some((91, 73).into())
    );
    h.state.execute_command(C::CloseWindow(b_id))?;
    h.pump()?;
    assert_eq!(h.probe.closes, 1);
    assert!(h.state.desktop.get(b_id).is_some());
    b.surface.attach(None, 0, 0);
    b.surface.commit();
    h.pump()?;
    assert_eq!(h.state.space.elements().count(), 0);
    assert_eq!(h.state.desktop.focused(), None);
    b.surface.commit();
    h.pump()?;
    h.ack(&b)?;
    h.draw(&b, 320, 200)?;
    assert_eq!(h.state.views[1].id, b_id);
    assert_eq!(
        h.state.space.element_location(&h.state.views[1].window),
        Some((91, 73).into())
    );
    h.state.execute_command(C::RemoveWorkspace {
        id: second,
        fallback: first,
    })?;
    assert_eq!(h.state.space.elements().count(), 2);
    b.top.destroy();
    b.xdg.destroy();
    b.surface.destroy();
    h.pump()?;
    assert_eq!(
        h.state.execute_command(C::FocusWindow(Some(b_id))),
        Err(CommandError::UnknownWindow)
    );
    assert_eq!(h.state.views.len(), 1);
    assert_eq!(h.state.desktop.focused(), Some(a_id));
    a.top.destroy();
    a.xdg.destroy();
    a.surface.destroy();
    h.pump()?;
    assert_eq!(h.state.space.elements().count(), 0);
    Ok(())
}

#[test]
fn command_resize_waits_for_ack_commit_and_transient_wire_parent_is_resolved() -> Result<()> {
    let mut h = Harness::new()?;
    let a = h.window()?;
    let b = h.window()?;
    let a_id = h.state.views[0].id;
    let b_id = h.state.views[1].id;
    b.top.set_parent(Some(&a.top));
    h.pump()?;
    assert_eq!(h.state.desktop.get(b_id).ok_or("b")?.parent, Some(a_id));
    let desired = Size::new(450, 250).ok_or("size")?;
    h.state.execute_command(C::ResizeWindow {
        id: a_id,
        size: desired,
    })?;
    h.pump()?;
    assert!(h.state.views[0].resize_flight.is_some());
    h.draw(&a, 340, 210)?; // deliberately commit a different buffer without ACK
    assert_eq!(
        h.state.desktop.get(a_id).ok_or("a")?.size,
        Size::new(320, 200)
    );
    h.ack(&a)?;
    h.pump()?; // ACK alone does not apply size or release flight
    assert!(h.state.views[0].resize_flight.is_some());
    h.draw(&a, 450, 250)?;
    assert_eq!(h.state.desktop.get(a_id).ok_or("a")?.size, Some(desired));
    assert!(h.state.views[0].resize_flight.is_none());
    assert!(h.state.desktop.get(a_id).ok_or("a")?.resize.is_none());
    a.top.destroy();
    a.xdg.destroy();
    a.surface.destroy();
    h.pump()?;
    assert_eq!(h.state.desktop.get(b_id).ok_or("b")?.parent, None);
    Ok(())
}

#[test]
fn logical_output_geometry_matches_projected_smithay_output() -> Result<()> {
    use smithay::{
        output::{Mode, Output, PhysicalProperties, Subpixel},
        utils::Transform,
    };
    let mut h = Harness::new()?;
    let output = Output::new(
        "test".into(),
        PhysicalProperties {
            size: (0, 0).into(),
            subpixel: Subpixel::Unknown,
            make: "test".into(),
            model: "test".into(),
        },
    );
    let mode = Mode {
        size: (800, 600).into(),
        refresh: 60_000,
    };
    output.change_current_state(
        Some(mode),
        Some(Transform::Normal),
        None,
        Some((0, 0).into()),
    );
    h.state.space.map_output(&output, (0, 0));
    let geometry = Geometry {
        position: Position::default(),
        size: Size::new(800, 600).ok_or("size")?,
    };
    h.state.desktop.update_output(OutputId::Nested, geometry)?;
    h.state.output = Some(output.clone());
    let _a = h.window()?;
    let id = h.state.views[0].id;
    assert_eq!(h.state.desktop.output_for(id), Some(OutputId::Nested));
    let actual = h
        .state
        .space
        .output_geometry(&output)
        .ok_or("output geometry")?;
    assert_eq!(
        (actual.size.w as u32, actual.size.h as u32),
        (geometry.size.width.get(), geometry.size.height.get())
    );
    Ok(())
}

#[test]
fn reparent_to_hidden_workspace_cancels_core_and_adapter_resize() -> Result<()> {
    let mut h = Harness::new()?;
    let a = h.window()?;
    let b = h.window()?;
    let a_id = h.state.views[0].id;
    let b_id = h.state.views[1].id;
    let created = h.state.execute_command(C::CreateWorkspace)?;
    let second = match created.events.as_slice() {
        [Event::WorkspaceCreated(id)] => *id,
        _ => return Err("workspace".into()),
    };
    h.state.execute_command(C::MoveWindowToWorkspace {
        id: a_id,
        workspace: second,
    })?;
    h.state.execute_command(C::ResizeWindow {
        id: b_id,
        size: Size::new(450, 250).ok_or("size")?,
    })?;
    h.pump()?;
    assert!(h.state.views[1].resize_flight.is_some());
    b.top.set_parent(Some(&a.top));
    h.pump()?;
    assert_eq!(h.state.desktop.get(b_id).ok_or("b")?.workspace, second);
    assert!(h.state.desktop.get(b_id).ok_or("b")?.resize.is_none());
    assert!(h.state.views[1].resize_flight.is_none());
    assert_eq!(h.state.space.elements().count(), 0);
    h.state.execute_command(C::ActivateWorkspace(second))?;
    a.surface.attach(None, 0, 0);
    a.surface.commit();
    h.pump()?;
    assert_eq!(h.state.desktop.get(b_id).ok_or("b")?.parent, None);
    assert_eq!(h.state.space.elements().count(), 1);
    Ok(())
}
