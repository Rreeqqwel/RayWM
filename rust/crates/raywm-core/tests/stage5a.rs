use raywm_core::{
    commands::{Command as C, CommandError as E, Effect, Event},
    config::{ConfigError, Configuration},
    layout::{
        Floating, LayoutEngine, LayoutError, LayoutInput, LayoutKind, LayoutPlan, LayoutWindow,
        Presentation,
    },
    windows::{Desktop, Geometry, Lifecycle, OutputId, Position, Size, WindowId},
    workspaces::WorkspaceId,
};
use std::{collections::BTreeSet, error::Error};
type Result<T = ()> = std::result::Result<T, Box<dyn Error>>;

fn size() -> Size {
    Size::new(800, 600).unwrap_or(Size {
        width: std::num::NonZeroU32::MIN,
        height: std::num::NonZeroU32::MIN,
    })
}
fn bounds() -> Geometry {
    Geometry {
        position: Position::default(),
        size: size(),
    }
}
fn workspace(d: &mut Desktop) -> Result<WorkspaceId> {
    let result = d.execute(C::CreateWorkspace)?;
    match result.events.as_slice() {
        [Event::WorkspaceCreated(id)] => Ok(*id),
        _ => Err("missing workspace event".into()),
    }
}
fn mapped(d: &mut Desktop) -> Result<WindowId> {
    let id = d.create()?;
    assert!(d.map(id, Position { x: 20, y: 30 }, size()));
    Ok(id)
}
fn invariants(d: &Desktop) -> Result {
    assert!(d.workspace(d.active_workspace()).is_some());
    let order: BTreeSet<_> = d.stacking().iter().copied().collect();
    assert_eq!(order.len(), d.stacking().len());
    for w in d.windows() {
        assert!(d.workspace(w.workspace).is_some());
        assert_eq!(order.contains(&w.id), w.mapped());
        assert_eq!(w.focused, d.focused() == Some(w.id));
        if w.focused {
            assert!(d.focusable(w.id));
        }
        if let Some(parent) = w.parent {
            let parent = d.get(parent).ok_or("stale parent")?;
            assert_eq!(w.workspace, parent.workspace);
            if w.mapped() && parent.mapped() {
                assert!(
                    d.stacking().iter().position(|id| *id == parent.id)
                        < d.stacking().iter().position(|id| *id == w.id)
                );
            }
        }
    }
    for ws in d.workspaces() {
        if let Some(output) = ws.output {
            let output = d.output(output).ok_or("stale output")?;
            if let Some(active) = output.active {
                assert_eq!(d.workspace(active).ok_or("stale active")?.output, ws.output);
            }
        }
        let members: Vec<_> = d.workspace_windows(ws.id)?.collect();
        assert_eq!(
            members,
            d.windows()
                .filter(|w| w.workspace == ws.id)
                .map(|w| w.id)
                .collect::<Vec<_>>()
        );
    }
    Ok(())
}

#[test]
fn registry_lifecycle_remap_stable_ids_and_destroy_cleanup() -> Result {
    let mut d = Desktop::default();
    let a = d.create()?;
    let ws = d.active_workspace();
    assert_eq!(d.get(a).ok_or("window")?.lifecycle, Lifecycle::Created);
    assert!(!d.focus(Some(a)));
    assert!(d.map(a, Position { x: 50, y: 60 }, size()));
    assert!(d.focus(Some(a)));
    assert!(d.unmap(a));
    assert_eq!(d.get(a).ok_or("window")?.lifecycle, Lifecycle::Unmapped);
    assert_eq!(d.get(a).ok_or("window")?.workspace, ws);
    assert_eq!(d.focused(), None);
    let (position, size) = d.placement(a, size()).ok_or("placement")?;
    assert_eq!(position, Position { x: 50, y: 60 });
    d.map(a, position, size);
    d.map(a, position, size);
    assert_eq!(d.stacking(), &[a]);
    d.remove(a);
    assert_eq!(d.execute(C::FocusWindow(Some(a))), Err(E::UnknownWindow));
    assert!(!d.map(a, position, size));
    assert!(d.create()?.get() > a.get());
    invariants(&d)
}

#[test]
fn activation_transfer_hidden_focus_and_fallback() -> Result {
    let mut d = Desktop::default();
    let first = d.active_workspace();
    let second = workspace(&mut d)?;
    let a = mapped(&mut d)?;
    let b = mapped(&mut d)?;
    d.focus(Some(b));
    d.execute(C::MoveWindowToWorkspace {
        id: b,
        workspace: second,
    })?;
    assert!(!d.visible(b));
    assert_eq!(d.focused(), Some(a));
    assert_eq!(d.execute(C::FocusWindow(Some(b))), Err(E::NotVisible));
    d.execute(C::ActivateWorkspace(second))?;
    assert_eq!(d.focused(), Some(b));
    assert!(!d.visible(a));
    d.unmap(b);
    assert_eq!(d.focused(), None);
    d.execute(C::ActivateWorkspace(first))?;
    assert_eq!(d.focused(), Some(a));
    invariants(&d)
}

#[test]
fn removal_transfers_mapped_and_unmapped_and_never_recycles_workspace() -> Result {
    let mut d = Desktop::default();
    let first = d.active_workspace();
    assert_eq!(
        d.execute(C::RemoveWorkspace {
            id: first,
            fallback: first
        }),
        Err(E::LastWorkspace)
    );
    let second = workspace(&mut d)?;
    assert_eq!(
        d.execute(C::RemoveWorkspace {
            id: first,
            fallback: first
        }),
        Err(E::InvalidFallback)
    );
    let a = mapped(&mut d)?;
    let b = d.create()?;
    d.execute(C::RemoveWorkspace {
        id: first,
        fallback: second,
    })?;
    assert_eq!(d.workspace_windows(second)?.collect::<Vec<_>>(), vec![a, b]);
    assert_eq!(d.active_workspace(), second);
    assert_eq!(
        d.execute(C::MoveWindowToWorkspace {
            id: a,
            workspace: first
        }),
        Err(E::UnknownWorkspace)
    );
    assert_eq!(
        d.execute(C::ActivateWorkspace(first)),
        Err(E::UnknownWorkspace)
    );
    assert!(workspace(&mut d)?.get() > second.get());
    d.remove(a);
    d.remove(b);
    assert!(d.workspace(second).is_some());
    invariants(&d)
}

#[test]
fn output_attach_switch_rebind_remove_and_reappear() -> Result {
    let mut d = Desktop::default();
    let first = d.active_workspace();
    let a = mapped(&mut d)?;
    d.update_output(OutputId::Nested, bounds())?;
    assert_eq!(d.output_for(a), Some(OutputId::Nested));
    let second = workspace(&mut d)?;
    d.execute(C::BindWorkspace {
        id: second,
        output: Some(OutputId::Nested),
    })?;
    d.execute(C::ActivateWorkspace(second))?;
    let b = mapped(&mut d)?;
    assert!(!d.visible(a));
    let other = OutputId::Virtual(2);
    d.update_output(other, bounds())?;
    assert_eq!(d.output(other).ok_or("output")?.active, None);
    d.execute(C::BindWorkspace {
        id: first,
        output: Some(other),
    })?;
    assert!(d.visible(a) && d.visible(b));
    d.focus(Some(a));
    assert_eq!(d.active_workspace(), first);
    d.remove_output(other)?;
    assert!(!d.visible(a));
    assert_eq!(d.output_for(a), None);
    assert_eq!(d.focused(), Some(b));
    d.remove_output(OutputId::Nested)?;
    assert_eq!(d.workspace(second).ok_or("workspace")?.output, None);
    assert_eq!(d.get(a).ok_or("window")?.workspace, first);
    d.update_output(OutputId::Nested, bounds())?;
    assert_eq!(d.output_for(b), Some(OutputId::Nested));
    assert_eq!(
        d.execute(C::BindWorkspace {
            id: first,
            output: Some(other)
        }),
        Err(E::UnknownOutput)
    );
    assert_eq!(d.remove_output(other), Err(E::UnknownOutput));
    invariants(&d)
}

#[test]
fn detached_workspace_activation_and_removal_are_explicit() -> Result {
    let mut d = Desktop::default();
    let first = d.active_workspace();
    let second = workspace(&mut d)?;
    d.update_output(OutputId::Nested, bounds())?;
    assert_eq!(
        d.execute(C::ActivateWorkspace(second)),
        Err(E::UnknownOutput)
    );
    d.execute(C::BindWorkspace {
        id: second,
        output: Some(OutputId::Nested),
    })?;
    d.execute(C::RemoveWorkspace {
        id: first,
        fallback: second,
    })?;
    assert_eq!(
        d.output(OutputId::Nested).ok_or("output")?.active,
        Some(second)
    );
    d.execute(C::BindWorkspace {
        id: second,
        output: None,
    })?;
    assert_eq!(d.output(OutputId::Nested).ok_or("output")?.active, None);
    invariants(&d)
}

#[test]
fn transient_family_transfer_stacking_cycles_and_parent_destruction() -> Result {
    let mut d = Desktop::default();
    let a = mapped(&mut d)?;
    let b = mapped(&mut d)?;
    let c = mapped(&mut d)?;
    d.set_parent(b, Some(a))?;
    d.set_parent(c, Some(b))?;
    assert_eq!(d.set_parent(a, Some(c)), Err(E::InvalidParent));
    assert_eq!(d.set_parent(a, Some(a)), Err(E::InvalidParent));
    d.focus(Some(a));
    assert_eq!(d.stacking(), &[a, b, c]);
    let ws = workspace(&mut d)?;
    d.execute(C::MoveWindowToWorkspace {
        id: b,
        workspace: ws,
    })?;
    assert_eq!(d.workspace_windows(ws)?.collect::<Vec<_>>(), vec![a, b, c]);
    d.execute(C::ActivateWorkspace(ws))?;
    d.remove(b);
    assert_eq!(d.get(c).ok_or("child")?.parent, None);
    assert_eq!(d.set_parent(c, Some(b)), Err(E::UnknownWindow));
    d.unmap(a);
    assert_eq!(d.get(c).ok_or("child")?.workspace, ws);
    invariants(&d)
}

#[test]
fn commands_reject_busy_stale_and_unsupported_without_mutation() -> Result {
    let mut d = Desktop::default();
    let a = mapped(&mut d)?;
    let b = d.create()?;
    let ws = workspace(&mut d)?;
    assert_eq!(
        d.execute(C::MoveWindow {
            id: b,
            position: Position::default()
        }),
        Err(E::NotMapped)
    );
    assert_eq!(d.execute(C::ToggleFloating(a)), Err(E::Unsupported));
    assert_eq!(
        d.execute(C::SetPresentation {
            id: a,
            presentation: Presentation::Fullscreen
        }),
        Err(E::Unsupported)
    );
    assert_eq!(
        d.execute(C::SetLayout {
            id: ws,
            layout: LayoutKind::Tiling
        }),
        Err(E::Unsupported)
    );
    assert!(d.begin_move(a, Position::default()));
    assert_eq!(
        d.execute(C::MoveWindowToWorkspace {
            id: a,
            workspace: ws
        }),
        Err(E::Busy)
    );
    assert_eq!(d.execute(C::ActivateWorkspace(ws)), Err(E::Busy));
    assert_eq!(
        d.execute(C::ApplyConfiguration(Configuration::default())),
        Err(E::Busy)
    );
    d.unmap(a);
    assert_eq!(d.interaction_window(), None);
    d.remove(b);
    assert_eq!(d.execute(C::CloseWindow(b)), Err(E::UnknownWindow));
    invariants(&d)
}

#[test]
fn command_effects_resize_coalescing_and_committed_geometry_are_distinct() -> Result {
    let mut d = Desktop::default();
    let a = mapped(&mut d)?;
    assert_eq!(
        d.execute(C::CloseWindow(a))?.effects,
        vec![Effect::CloseWindow(a)]
    );
    assert!(d.get(a).is_some());
    let desired = Size::new(400, 300).ok_or("size")?;
    d.execute(C::ResizeWindow {
        id: a,
        size: desired,
    })?;
    assert_eq!(d.get(a).ok_or("window")?.size, Some(size()));
    assert_eq!(d.resize_request(a), Some((desired, false)));
    assert_eq!(
        d.execute(C::MoveWindow {
            id: a,
            position: Position::default()
        }),
        Err(E::Busy)
    );
    d.mark_resize_sent(a, (desired, false));
    assert_eq!(d.resize_request(a), None);
    d.commit_size(a, desired);
    d.finish_resize(a);
    assert_eq!(d.get(a).ok_or("window")?.size, Some(desired));
    let invalid = Size::new(u32::MAX, 1).ok_or("size")?;
    assert_eq!(
        d.execute(C::ResizeWindow {
            id: a,
            size: invalid
        }),
        Err(E::InvalidGeometry)
    );
    invariants(&d)
}

#[test]
fn configuration_defaults_validation_atomic_replacement_and_placement() -> Result {
    let mut d = Desktop::default();
    let default = Configuration::default();
    default.validate()?;
    assert_eq!(default.floating.cascade_step, 48);
    assert_eq!(default.floating.cascade_slots, 5);
    assert_eq!(default.floating.secondary_percent, 60);
    let a = mapped(&mut d)?;
    for (step, slots, percent, error) in [
        (4097, 5, 60, ConfigError::CascadeStep),
        (48, 0, 60, ConfigError::CascadeSlots),
        (48, 257, 60, ConfigError::CascadeSlots),
        (48, 5, 0, ConfigError::SecondaryPercent),
        (48, 5, 101, ConfigError::SecondaryPercent),
    ] {
        let mut bad = default.clone();
        bad.floating.cascade_step = step;
        bad.floating.cascade_slots = slots;
        bad.floating.secondary_percent = percent;
        assert_eq!(
            d.execute(C::ApplyConfiguration(bad)),
            Err(E::Configuration(error))
        );
        assert_eq!(d.configuration(), &default);
    }
    let mut config = default;
    config.floating.cascade_step = 24;
    config.floating.secondary_percent = 50;
    d.execute(C::ApplyConfiguration(config))?;
    let b = d.create()?;
    assert_eq!(
        d.placement(b, size()),
        Some((
            Position { x: 24, y: 24 },
            Size::new(400, 300).ok_or("size")?
        ))
    );
    assert_eq!(
        d.get(a).ok_or("window")?.position,
        Position { x: 20, y: 30 }
    );
    invariants(&d)
}

#[test]
fn floating_fullscreen_maximized_plans_are_pure_and_validated() -> Result {
    let mut d = Desktop::default();
    let id = mapped(&mut d)?;
    let geometry = Geometry {
        position: Position { x: -100, y: 45 },
        size: size(),
    };
    let mut window = LayoutWindow {
        id,
        geometry,
        floating: true,
        presentation: Presentation::Normal,
    };
    let calculate = |window| {
        Floating.arrange(&LayoutInput {
            bounds: Some(bounds()),
            windows: &[window],
        })
    };
    let plan = calculate(window).map_err(|e| format!("{e:?}"))?;
    assert_eq!(plan.placements[0].geometry, geometry);
    assert_eq!(calculate(window), Ok(plan.clone()));
    for state in [Presentation::Fullscreen, Presentation::Maximized] {
        window.presentation = state;
        assert_eq!(
            calculate(window).map_err(|e| format!("{e:?}"))?.placements[0].geometry,
            bounds()
        );
        assert_eq!(
            Floating.arrange(&LayoutInput {
                bounds: None,
                windows: &[window]
            }),
            Err(LayoutError::MissingOutput)
        );
    }
    assert_eq!(
        LayoutKind::Tiling.arrange(&LayoutInput {
            bounds: None,
            windows: &[]
        }),
        Err(LayoutError::Unsupported)
    );
    assert_eq!(
        Floating.arrange(&LayoutInput {
            bounds: None,
            windows: &[window, window]
        }),
        Err(LayoutError::MissingOutput)
    );
    window.presentation = Presentation::Normal;
    assert_eq!(
        Floating.arrange(&LayoutInput {
            bounds: None,
            windows: &[window, window]
        }),
        Err(LayoutError::DuplicateWindow)
    );
    assert_eq!(
        LayoutPlan { placements: vec![] }.validate(&LayoutInput {
            bounds: None,
            windows: &[window]
        }),
        Err(LayoutError::InvalidPlan)
    );
    let stale = d.create()?;
    let mut invalid = plan;
    invalid.placements[0].id = stale;
    assert_eq!(
        invalid.validate(&LayoutInput {
            bounds: None,
            windows: &[window]
        }),
        Err(LayoutError::InvalidPlan)
    );
    invariants(&d)
}

#[test]
fn output_loss_cancels_resize_and_retains_membership() -> Result {
    let mut d = Desktop::default();
    let a = mapped(&mut d)?;
    let ws = d.active_workspace();
    d.update_output(OutputId::Nested, bounds())?;
    d.execute(C::ResizeWindow {
        id: a,
        size: size(),
    })?;
    d.remove_output(OutputId::Nested)?;
    assert_eq!(d.resize_request(a), None);
    assert_eq!(d.get(a).ok_or("window")?.workspace, ws);
    assert_eq!(d.output_for(a), None);
    invariants(&d)
}

#[test]
fn deterministic_lifecycle_command_sequences_preserve_invariants() -> Result {
    let mut d = Desktop::default();
    let workspaces = [d.active_workspace(), workspace(&mut d)?, workspace(&mut d)?];
    let mut ids = Vec::new();
    for step in 0..600 {
        if step % 7 == 0 {
            ids.push(mapped(&mut d)?);
        }
        if !ids.is_empty() {
            let id = ids[step % ids.len()];
            match step % 6 {
                0 => {
                    let _ = d.execute(C::MoveWindowToWorkspace {
                        id,
                        workspace: workspaces[step % 3],
                    });
                }
                1 => {
                    let _ = d.execute(C::ActivateWorkspace(workspaces[step % 3]));
                }
                2 => {
                    d.unmap(id);
                }
                3 => {
                    d.map(id, Position::default(), size());
                }
                4 => {
                    d.focus(Some(id));
                }
                _ => {
                    d.remove(id);
                }
            }
        }
        invariants(&d)?;
    }
    Ok(())
}
