use raywm_core::{
    commands::{Command as C, CommandError},
    layout::{
        Gaps, LayoutEngine, LayoutError, LayoutInput, LayoutKind as L, LayoutParameters,
        LayoutWindow, MasterRatio, Presentation,
    },
    windows::{Desktop, Geometry, OutputId, Position, Size, SizeHints, WindowId},
};

type Result<T = ()> = std::result::Result<T, Box<dyn std::error::Error>>;
fn rect(x: i32, y: i32, w: u32, h: u32) -> Result<Geometry> {
    Ok(Geometry {
        position: Position { x, y },
        size: Size::new(w, h).ok_or("empty rectangle")?,
    })
}
fn windows(count: usize) -> Result<Vec<LayoutWindow>> {
    let mut desktop = Desktop::default();
    (0..count)
        .map(|_| {
            Ok(LayoutWindow {
                id: desktop.create()?,
                geometry: rect(0, 0, 320, 200)?,
                floating: false,
                presentation: Presentation::Normal,
                hints: SizeHints::default(),
            })
        })
        .collect()
}

#[test]
fn master_stack_uses_usable_origin_ratio_gaps_and_stable_order() -> Result {
    let windows = windows(3)?;
    let input = LayoutInput {
        bounds: Some(rect(-50, 0, 1200, 600)?),
        usable: Some(rect(-20, 50, 1000, 500)?),
        parameters: Default::default(),
        active_tile: Some(windows[2].id),
        windows: &windows,
    };
    let plan = L::MasterStack
        .arrange(&input)
        .map_err(|e| format!("{e:?}"))?;
    for (index, (p, expected)) in plan
        .placements
        .iter()
        .zip([
            rect(-12, 58, 536, 484)?,
            rect(532, 58, 440, 238)?,
            rect(532, 304, 440, 238)?,
        ])
        .enumerate()
    {
        assert_eq!(p.geometry, expected);
        assert_eq!(p.id, windows[index].id);
        assert!(p.tiled && p.visible);
    }
    for (percent, width) in [(10, 97), (90, 878)] {
        let mut input = LayoutInput { ..input };
        input.parameters.master_ratio = MasterRatio::new(percent).ok_or("ratio")?;
        let plan = L::MasterStack
            .arrange(&input)
            .map_err(|e| format!("{e:?}"))?;
        assert_eq!(plan.placements[0].geometry.size.width.get(), width);
    }
    assert!(MasterRatio::new(9).is_none() && MasterRatio::new(91).is_none());
    let one = L::MasterStack
        .arrange(&LayoutInput {
            windows: &windows[..1],
            ..input
        })
        .map_err(|e| format!("{e:?}"))?;
    assert_eq!(one.placements[0].geometry, rect(-12, 58, 984, 484)?);
    let mut input = input;
    input.parameters.master_count = std::num::NonZeroUsize::new(2).ok_or("master count")?;
    let plan = L::MasterStack
        .arrange(&input)
        .map_err(|e| format!("{e:?}"))?;
    assert_eq!(plan.placements[1].geometry, rect(-12, 304, 536, 238)?);
    Ok(())
}

#[test]
fn columns_round_to_exact_extent_and_respect_feasible_hints() -> Result {
    let mut windows = windows(3)?;
    windows[0].hints.min.0 = 48;
    windows[1].hints.max.1 = 20;
    let input = LayoutInput {
        bounds: Some(rect(10, -40, 101, 99)?),
        usable: None,
        parameters: LayoutParameters {
            gaps: Gaps { inner: 3, outer: 0 },
            ..Default::default()
        },
        active_tile: None,
        windows: &windows,
    };
    let plan = L::Columns.arrange(&input).map_err(|e| format!("{e:?}"))?;
    assert_eq!(plan.placements[0].geometry, rect(10, -40, 48, 99)?);
    assert_eq!(plan.placements[1].geometry, rect(61, -40, 24, 20)?);
    assert_eq!(plan.placements[2].geometry, rect(88, -40, 23, 99)?);
    assert_eq!(L::Columns.arrange(&input), Ok(plan));
    Ok(())
}

#[test]
fn generated_pathological_sizes_and_constraints_produce_valid_contained_plans() -> Result {
    let mut all = windows(100)?;
    let mut seed = 148_321_u32;
    let mut random = || {
        seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        seed
    };
    for index in 0..256 {
        for w in &mut all {
            w.hints = SizeHints {
                min: (random() % 150, random() % 150),
                max: (random() % 300, random() % 300),
            };
        }
        let bounds = rect(
            -80,
            21,
            if index % 16 == 0 {
                1
            } else {
                1 + random() % 300
            },
            if index % 5 == 0 { 1 } else { 1 + random() % 90 },
        )?;
        let input = LayoutInput {
            bounds: Some(bounds),
            usable: None,
            active_tile: Some(all[0].id),
            parameters: LayoutParameters {
                gaps: Gaps {
                    inner: random() % 4500,
                    outer: random() % 20,
                },
                ..Default::default()
            },
            windows: &all[..index % 101],
        };
        for layout in [L::MasterStack, L::Columns, L::Monocle] {
            let plan = layout.arrange(&input).map_err(|e| format!("{e:?}"))?;
            assert_eq!(plan.validate(&input), Ok(()));
            assert_eq!(plan.placements.len(), input.windows.len());
            assert_eq!(layout.arrange(&input), Ok(plan));
        }
    }
    Ok(())
}

#[test]
fn monocle_rejects_foreign_visible_geometry_and_keeps_floating_window() -> Result {
    let mut windows = windows(3)?;
    windows[2].floating = true;
    let input = LayoutInput {
        bounds: Some(rect(200, 0, 500, 500)?),
        usable: None,
        parameters: Default::default(),
        active_tile: Some(windows[1].id),
        windows: &windows,
    };
    let mut plan = L::Monocle.arrange(&input).map_err(|e| format!("{e:?}"))?;
    assert!(!plan.placements[0].visible);
    assert!(plan.placements[1].visible);
    assert_eq!(plan.placements[2].geometry, windows[2].geometry);
    plan.placements[1].geometry.position.x = 0;
    assert_eq!(plan.validate(&input), Err(LayoutError::InvalidPlan));
    Ok(())
}

fn map(d: &mut Desktop, x: i32) -> Result<WindowId> {
    let id = d.create()?;
    let geometry = rect(x, 40, 300, 200)?;
    assert!(d.map(id, geometry.position, geometry.size));
    Ok(id)
}

#[test]
fn fullscreen_maximized_and_tiled_share_an_independent_floating_restore_box() -> Result {
    let mut d = Desktop::hybrid(L::MasterStack);
    d.update_output_area(
        OutputId::Nested,
        rect(0, 0, 900, 600)?,
        rect(0, 40, 900, 560)?,
    )?;
    let ws = d.active_workspace();
    let first = map(&mut d, 25)?;
    let second = map(&mut d, 85)?;
    d.focus(Some(first));
    assert_eq!(
        d.execute(C::MoveWindow {
            id: first,
            position: Position::default()
        }),
        Err(CommandError::InvalidMode)
    );
    d.execute(C::ToggleFloating(first))?;
    let saved = d.get(first).and_then(|w| w.floating_geometry);
    d.execute(C::ToggleMaximized(first))?;
    d.execute(C::ToggleFullscreen(first))?;
    assert!(d.visible(first) && !d.visible(second));
    let full = d.layout_plan(ws).map_err(|e| format!("{e:?}"))?;
    assert_eq!(full.placements[0].geometry, rect(0, 0, 900, 600)?);
    d.commit_size(first, rect(0, 0, 900, 600)?.size);
    assert_eq!(d.get(first).and_then(|w| w.floating_geometry), saved);
    d.protocol_presentation(first, true, false)?;
    let max = d.layout_plan(ws).map_err(|e| format!("{e:?}"))?;
    assert_eq!(max.placements[0].presentation, Presentation::Maximized);
    assert_eq!(max.placements[0].geometry, rect(0, 40, 900, 560)?);
    d.execute(C::ToggleMaximized(first))?;
    assert_eq!(
        d.layout_plan(ws).map_err(|e| format!("{e:?}"))?.placements[0].geometry,
        saved.ok_or("restore")?
    );
    d.execute(C::ToggleFloating(first))?;
    d.execute(C::ToggleMaximized(first))?;
    d.execute(C::ToggleMaximized(first))?;
    assert!(d.layout_plan(ws).map_err(|e| format!("{e:?}"))?.placements[0].tiled);
    Ok(())
}

#[test]
fn focus_reorder_workspace_transfer_and_fullscreen_destroy_reconcile() -> Result {
    let mut d = Desktop::hybrid(L::Monocle);
    d.update_output(OutputId::Nested, rect(0, 0, 900, 600)?)?;
    let ws = d.active_workspace();
    let a = map(&mut d, 20)?;
    let b = map(&mut d, 40)?;
    assert!(d.focus(Some(b)));
    assert!(d.visible(b) && !d.visible(a));
    d.execute(C::FocusPrevious)?;
    assert_eq!(d.focused(), Some(a));
    assert!(d.visible(a) && !d.visible(b));
    d.execute(C::ReorderWindow {
        id: a,
        forward: true,
    })?;
    assert_eq!(
        d.layout_plan(ws).map_err(|e| format!("{e:?}"))?.placements[0].id,
        b
    );
    d.execute(C::ToggleFullscreen(a))?;
    d.remove(a);
    assert_eq!(d.focused(), Some(b));
    let second = d.workspace_number(2).ok_or("workspace")?;
    d.execute(C::MoveWindowToWorkspace {
        id: b,
        workspace: second,
    })?;
    assert_eq!(d.focused(), None);
    d.execute(C::NextWorkspace)?;
    assert_eq!(d.focused(), Some(b));
    d.execute(C::PreviousWorkspace)?;
    assert_eq!(d.active_workspace(), ws);
    for _ in 0..24 {
        d.execute(C::CycleLayout(ws))?;
    }
    assert_eq!(d.workspace(ws).ok_or("workspace")?.layout, L::Monocle);
    Ok(())
}

#[test]
fn output_fallback_reclaims_identity_after_resize_loss_and_reappearance() -> Result {
    let mut d = Desktop::hybrid(L::Columns);
    let primary = OutputId::Nested;
    let other = OutputId::Virtual(18);
    d.update_output(primary, rect(0, 0, 800, 600)?)?;
    d.update_output(other, rect(-700, 0, 700, 500)?)?;
    let detached = d.workspace_number(9).ok_or("workspace 9")?;
    d.execute(C::BindWorkspace {
        id: detached,
        output: None,
    })?;
    let ws = d.workspace_number(2).ok_or("workspace")?;
    d.execute(C::BindWorkspace {
        id: ws,
        output: Some(other),
    })?;
    d.execute(C::ActivateWorkspace(ws))?;
    let a = map(&mut d, -400)?;
    d.focus(Some(a));
    let layout_box = |d: &Desktop| -> Result<Geometry> {
        Ok(d.layout_plan(ws).map_err(|e| format!("{e:?}"))?.placements[0].geometry)
    };
    assert_eq!(layout_box(&d)?, rect(-692, 8, 684, 484)?);
    d.update_output(other, rect(-650, 0, 650, 450)?)?;
    assert_eq!(layout_box(&d)?, rect(-642, 8, 634, 434)?);
    d.remove_output(other)?;
    assert_eq!(d.output_for(a), Some(primary));
    assert!(!d.visible(a));
    d.execute(C::ActivateWorkspace(ws))?;
    assert_eq!(layout_box(&d)?, rect(8, 8, 784, 584)?);
    d.remove_output(primary)?;
    assert!(!d.visible(a));
    assert_eq!(d.focused(), None);
    d.update_output(other, rect(-650, 0, 650, 450)?)?;
    assert_eq!(layout_box(&d)?, rect(-642, 8, 634, 434)?);
    assert_eq!(d.workspace(detached).ok_or("workspace 9")?.output, None);
    assert_eq!(d.focused(), Some(a));
    Ok(())
}

#[test]
fn workspace_focus_restores_the_exact_member_of_a_transient_family() -> Result {
    let mut d = Desktop::hybrid(L::MasterStack);
    d.update_output(OutputId::Nested, rect(0, 0, 800, 600)?)?;
    let ws = d.active_workspace();
    let root = map(&mut d, 20)?;
    let child = map(&mut d, 40)?;
    d.set_parent(child, Some(root))?;
    assert!(d.focus(Some(root)));
    assert_eq!(d.stacking().last(), Some(&child));
    d.execute(C::NextWorkspace)?;
    d.execute(C::ActivateWorkspace(ws))?;
    assert_eq!(d.focused(), Some(root));
    d.remove(root);
    assert_eq!(d.focused(), Some(child));
    d.execute(C::NextWorkspace)?;
    d.execute(C::PreviousWorkspace)?;
    assert_eq!(d.focused(), Some(child));
    Ok(())
}

#[test]
fn layout_settings_and_workspace_switch_do_not_wait_for_an_unresponsive_floating_resize() -> Result
{
    let mut d = Desktop::hybrid(L::MasterStack);
    d.update_output(OutputId::Nested, rect(0, 0, 800, 600)?)?;
    let first = d.active_workspace();
    let a = map(&mut d, 20)?;
    d.focus(Some(a));
    d.execute(C::ToggleFloating(a))?;
    let desired = rect(0, 0, 380, 250)?.size;
    d.execute(C::ResizeWindow {
        id: a,
        size: desired,
    })?;
    d.mark_resize_sent(a, (desired, false));
    d.execute(C::NextWorkspace)?;
    assert!(!d.visible(a));
    d.execute(C::ActivateWorkspace(first))?;
    assert_eq!(d.focused(), Some(a));
    assert!(d.get(a).ok_or("window")?.resize.is_some());
    d.execute(C::ToggleFloating(a))?;
    assert!(d.get(a).ok_or("window")?.resize.is_none());
    let ratio = MasterRatio::new(63).ok_or("ratio")?;
    d.execute(C::SetMasterRatio(ratio))?;
    d.execute(C::SetGaps(Gaps {
        inner: 5,
        outer: 10,
    }))?;
    assert_eq!(d.configuration().layout.master_ratio, ratio);
    let plan = d.layout_plan(first).map_err(|e| format!("{e:?}"))?;
    assert_eq!(plan.placements[0].geometry, rect(10, 10, 780, 580)?);
    assert!(matches!(
        d.execute(C::SetGaps(Gaps {
            inner: 5000,
            outer: 0
        })),
        Err(CommandError::Configuration(_))
    ));
    assert_eq!(
        d.configuration().layout.gaps,
        Gaps {
            inner: 5,
            outer: 10
        }
    );
    Ok(())
}
