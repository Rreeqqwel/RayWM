use super::*;
use raywm_core::{
    layout::{LayoutKind, Presentation},
    windows::{Desktop, WindowId},
};
use smithay::{
    output::{Mode, Output, PhysicalProperties, Subpixel},
    utils::Transform,
};
use xdg_toplevel::State as Flag;

fn output(h: &mut Harness, id: OutputId, x: i32, size: (i32, i32)) -> Result<Output> {
    let output = Output::new(
        format!("{id:?}"),
        PhysicalProperties {
            size: (0, 0).into(),
            subpixel: Subpixel::Unknown,
            make: "RayWM tests".into(),
            model: "virtual".into(),
        },
    );
    output.change_current_state(
        Some(Mode {
            size: size.into(),
            refresh: 60000,
        }),
        Some(Transform::Normal),
        None,
        Some((x, 0).into()),
    );
    h.state.observe_output(id, &output)?;
    Ok(output)
}

fn desktop(h: &mut Harness, layout: LayoutKind) -> Result<Output> {
    h.state.desktop = Desktop::hybrid(layout);
    h.state.host_focused = true;
    output(h, OutputId::Nested, 0, (800, 600))
}

fn serial(h: &Harness, window: &Window) -> Result<u32> {
    h.probe
        .configures
        .iter()
        .rev()
        .find(|(s, _)| s == &window.xdg)
        .map(|(_, serial)| *serial)
        .ok_or_else(|| "missing configure".into())
}

fn configure<'a>(h: &'a Harness, window: &Window) -> Result<((i32, i32), &'a [u32])> {
    h.probe
        .top_configures
        .iter()
        .rev()
        .find(|(top, _, _)| top == &window.top)
        .map(|(_, size, flags)| (*size, flags.as_slice()))
        .ok_or_else(|| "missing toplevel configure".into())
}

fn size(h: &Harness, id: WindowId) -> Result<(u32, u32)> {
    let size = h
        .state
        .desktop
        .get(id)
        .and_then(|w| w.size)
        .ok_or("no committed size")?;
    Ok((size.width.get(), size.height.get()))
}

#[test]
fn wire_layout_resize_coalesces_while_client_holds_an_unacked_buffer() -> Result<()> {
    let mut h = Harness::new()?;
    desktop(&mut h, LayoutKind::MasterStack)?;
    let a = h.window()?;
    let id = h.state.views[0].id;
    let earlier = serial(&h, &a)?;
    let (tile, flags) = configure(&h, &a)?;
    assert_eq!(tile, (784, 584));
    assert!(flags.contains(&(Flag::TiledLeft as u32)));
    let b = h.window()?;
    let b_id = h.state.views[1].id;
    assert_eq!(
        h.state.space.element_location(&h.state.views[0].window),
        Some((8, 8).into())
    );
    assert_eq!(
        h.state.space.element_location(&h.state.views[1].window),
        Some((442, 8).into())
    );
    let held = h
        .probe
        .top_configures
        .iter()
        .filter(|(top, _, _)| top == &a.top)
        .count();
    h.draw(&a, 350, 260)?;
    h.draw(&a, 360, 270)?;
    assert_eq!(size(&h, id)?, (320, 200));
    assert_eq!(
        h.probe
            .top_configures
            .iter()
            .filter(|(top, _, _)| top == &a.top)
            .count(),
        held
    );
    a.xdg.ack_configure(earlier);
    h.pump()?;
    assert_eq!(size(&h, id)?, (320, 200));
    h.draw(&a, tile.0, tile.1)?;
    assert_eq!(size(&h, id)?, (784, 584));
    let (narrow, _) = configure(&h, &a)?;
    assert_eq!(narrow, (426, 584));
    h.ack(&a)?;
    // The client acknowledged the request but kept an independently sized buffer.
    h.draw(&a, 355, 222)?;
    assert_eq!(size(&h, id)?, (355, 222));
    assert_eq!(
        h.state.views[0].managed_box.ok_or("clip")?.size.width.get(),
        426
    );
    h.ack(&b)?;
    let (b_size, _) = configure(&h, &b)?;
    h.draw(&b, b_size.0, b_size.1)?;
    h.state
        .execute_command(C::CycleLayout(h.state.desktop.active_workspace()))?;
    h.pump()?;
    let (columns, _) = configure(&h, &a)?;
    assert_eq!(columns, (388, 584));
    assert_eq!(h.state.desktop.focused(), Some(b_id));
    Ok(())
}

#[test]
fn wire_client_presentation_requests_match_configure_commit_and_restore() -> Result<()> {
    let mut h = Harness::new()?;
    desktop(&mut h, LayoutKind::MasterStack)?;
    let a = h.window()?;
    let id = h.state.views[0].id;
    h.state.execute_command(C::ToggleFloating(id))?;
    h.pump()?;
    h.ack(&a)?;
    h.draw(&a, 320, 200)?;
    h.state.execute_command(C::MoveWindow {
        id,
        position: Position { x: 44, y: 65 },
    })?;
    let restore = h.state.desktop.get(id).and_then(|w| w.floating_geometry);
    a.top.set_maximized();
    h.pump()?;
    let max = serial(&h, &a)?;
    let (target, flags) = configure(&h, &a)?;
    assert_eq!(target, (800, 600));
    assert!(flags.contains(&(Flag::Maximized as u32)));
    a.top.set_fullscreen(None);
    h.pump()?;
    let fullscreen = serial(&h, &a)?;
    assert_ne!(fullscreen, max);
    let (_, flags) = configure(&h, &a)?;
    assert!(flags.contains(&(Flag::Fullscreen as u32)));
    a.xdg.ack_configure(max);
    h.draw(&a, 800, 600)?;
    assert_eq!(size(&h, id)?, (320, 200));
    a.xdg.ack_configure(fullscreen);
    h.draw(&a, 640, 480)?;
    assert_eq!(size(&h, id)?, (640, 480));
    assert_eq!(
        h.state.space.element_location(&h.state.views[0].window),
        Some((80, 60).into())
    );
    assert_eq!(
        h.state.desktop.get(id).and_then(|w| w.floating_geometry),
        restore
    );
    a.top.unset_fullscreen();
    h.pump()?;
    let (_, flags) = configure(&h, &a)?;
    assert!(
        flags.contains(&(Flag::Maximized as u32)) && !flags.contains(&(Flag::Fullscreen as u32))
    );
    a.top.unset_maximized();
    h.pump()?;
    let (target, flags) = configure(&h, &a)?;
    assert_eq!(target, (320, 200));
    assert!(!flags.contains(&(Flag::Maximized as u32)));
    assert_eq!(
        h.state.space.element_location(&h.state.views[0].window),
        Some((44, 65).into())
    );
    h.ack(&a)?;
    h.pump()?;
    assert_eq!(size(&h, id)?, (640, 480));
    h.draw(&a, target.0, target.1)?;
    assert_eq!(size(&h, id)?, (320, 200));
    assert_eq!(
        h.state.desktop.get(id).and_then(|w| w.floating_geometry),
        restore
    );
    Ok(())
}

#[test]
fn tiled_to_floating_transfer_survives_late_ack_while_hidden() -> Result<()> {
    let mut h = Harness::new()?;
    desktop(&mut h, LayoutKind::MasterStack)?;
    let a = h.window()?;
    let id = h.state.views[0].id;
    let saved = h
        .state
        .desktop
        .get(id)
        .and_then(|w| w.floating_geometry)
        .ok_or("restore")?;
    let ws = h.state.desktop.workspace_number(2).ok_or("workspace")?;
    h.state.execute_command(C::SetLayout {
        id: ws,
        layout: LayoutKind::Floating,
    })?;
    h.state
        .execute_command(C::MoveWindowToWorkspace { id, workspace: ws })?;
    h.ack(&a)?;
    h.draw(&a, 784, 584)?;
    assert_eq!(
        h.state.desktop.get(id).and_then(|w| w.floating_geometry),
        Some(saved)
    );
    assert!(h.state.space.elements().next().is_none());
    h.state.execute_command(C::ActivateWorkspace(ws))?;
    h.pump()?;
    assert_eq!(configure(&h, &a)?.0, (320, 200));
    h.ack(&a)?;
    h.draw(&a, 320, 200)?;
    assert_eq!(h.state.desktop.focused(), Some(id));
    Ok(())
}

#[test]
fn monocle_focus_and_two_output_geometry_survive_fullscreen_destroy_and_rebind() -> Result<()> {
    let mut h = Harness::new()?;
    desktop(&mut h, LayoutKind::Monocle)?;
    let a = h.window()?;
    let id = h.state.views[0].id;
    let b = h.window()?;
    let b_id = h.state.views[1].id;
    assert_eq!(h.state.space.elements().count(), 1);
    assert_eq!(h.state.desktop.focused(), Some(b_id));
    h.state.execute_command(C::FocusPrevious)?;
    assert_eq!(h.state.desktop.focused(), Some(id));
    assert!(h
        .state
        .space
        .element_location(&h.state.views[1].window)
        .is_none());
    let second = h.state.desktop.workspace_number(2).ok_or("workspace")?;
    let virtual_id = OutputId::Virtual(2);
    let other = output(&mut h, virtual_id, -640, (640, 480))?;
    h.state.execute_command(C::BindWorkspace {
        id: second,
        output: Some(virtual_id),
    })?;
    h.state.execute_command(C::MoveWindowToWorkspace {
        id: b_id,
        workspace: second,
    })?;
    assert_eq!(h.state.space.elements_for_output(&other).count(), 1);
    h.state.execute_command(C::FocusNext)?;
    assert_eq!(h.state.desktop.focused(), Some(b_id));
    assert_eq!(
        h.state.space.element_location(&h.state.views[1].window),
        Some((-632, 8).into())
    );
    b.top.set_fullscreen(None);
    h.pump()?;
    assert_eq!(configure(&h, &b)?.0, (640, 480));
    h.state.forget_output(virtual_id, &other)?;
    assert!(!h.state.desktop.visible(b_id));
    assert_eq!(h.state.desktop.focused(), Some(id));
    output(&mut h, virtual_id, -560, (560, 360))?;
    assert!(h.state.desktop.visible(b_id));
    assert_eq!(
        h.state.desktop.get(b_id).ok_or("B")?.presentation,
        Presentation::Fullscreen
    );
    assert_eq!(
        h.state.space.element_location(&h.state.views[1].window),
        Some((-440, 80).into())
    );
    b.top.destroy();
    b.xdg.destroy();
    b.surface.destroy();
    h.pump()?;
    assert_eq!(h.state.space.elements().count(), 1);
    assert_eq!(h.state.desktop.focused(), Some(id));
    a.top.destroy();
    a.xdg.destroy();
    a.surface.destroy();
    h.pump()?;
    assert!(h.state.views.is_empty());
    assert_eq!(h.state.desktop.focused(), None);
    Ok(())
}
