//! One Winit window/output, using Smithay's EGL/GLES and desktop renderer.
//! Redraws are requested only for commits, resize, focus or host exposure.

use std::time::Instant;

use smithay::{
    backend::{
        renderer::{
            damage::OutputDamageTracker,
            element::surface::{render_elements_from_surface_tree, WaylandSurfaceRenderElement},
            element::AsRenderElements,
            element::{utils::CropRenderElement, Kind},
            gles::GlesRenderer,
        },
        winit::{self, WinitEventLoop, WinitGraphicsBackend},
    },
    delegate_output,
    desktop::{
        space::SurfaceTree,
        utils::{
            send_frames_surface_tree, surface_primary_scanout_output,
            update_surface_primary_scanout_output,
        },
        PopupManager,
    },
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::{
        wayland_server::DisplayHandle,
        winit::{dpi::LogicalSize, window::Window},
    },
    utils::{IsAlive, Physical, Point, Rectangle, Scale, Size, Transform},
    wayland::{
        compositor::SurfaceAttributes,
        output::{OutputHandler, OutputManagerState},
    },
};

use crate::{state::State, Result as AppResult};

pub struct Graphics {
    backend: WinitGraphicsBackend<GlesRenderer>,
    damage: OutputDamageTracker,
    pending: bool,
    start: Instant,
}

impl Graphics {
    pub fn new(state: &mut State, display: &DisplayHandle) -> AppResult<(Self, WinitEventLoop)> {
        // Winit connects using the incoming host environment. Never replace
        // WAYLAND_DISPLAY with the server's newly created client socket.
        let (backend, source) = winit::init_from_attributes::<GlesRenderer>(
            Window::default_attributes()
                .with_title("RayWM — Smithay")
                .with_inner_size(LogicalSize::new(800.0, 600.0)),
        )?;
        let mode = Mode {
            size: backend.window_size(),
            refresh: 60_000,
        };
        let output = Output::new(
            "raywm-nested".into(),
            PhysicalProperties {
                size: (0, 0).into(),
                subpixel: Subpixel::Unknown,
                make: "RayWM".into(),
                model: "Winit".into(),
            },
        );
        output.create_global::<State>(display);
        output.change_current_state(
            Some(mode),
            Some(Transform::Flipped180),
            None,
            Some((0, 0).into()),
        );
        output.set_preferred(mode);
        state.output_manager = Some(OutputManagerState::new_with_xdg_output::<State>(display));
        let mut seat = state.seat_state.new_wl_seat(display, "raywm-nested");
        seat.add_keyboard(Default::default(), 200, 25)?;
        seat.add_pointer();
        state.seat = Some(seat);
        use smithay::reexports::wayland_protocols::xdg::shell::server::xdg_toplevel::WmCapabilities;
        state
            .xdg
            .replace_capabilities([WmCapabilities::Maximize, WmCapabilities::Fullscreen]);
        state.output = Some(output.clone());
        state.observe_output(raywm_core::windows::OutputId::Nested, &output)?;
        state.redraw = true;
        tracing::info!(
            width = mode.size.w,
            height = mode.size.h,
            "Nested output initialized"
        );
        Ok((
            Self {
                backend,
                damage: OutputDamageTracker::from_output(&output),
                pending: false,
                start: Instant::now(),
            },
            source,
        ))
    }

    pub fn request_redraw(&mut self, state: &mut State) {
        if state.redraw && !self.pending {
            self.backend.window().request_redraw();
            self.pending = true;
        }
    }

    pub fn resize(&mut self, state: &mut State, size: Size<i32, Physical>) {
        // Minimized/zero-size targets are not EGL render targets. Wait for the
        // next positive resize instead of producing errors or a redraw loop.
        if size.w <= 0 || size.h <= 0 {
            return;
        }
        if let Some(output) = state.output.clone() {
            let previous = output.current_mode();
            let mode = Mode {
                size,
                refresh: 60_000,
            };
            output.change_current_state(Some(mode), None, None, None);
            output.set_preferred(mode);
            if let Some(previous) = previous.filter(|previous| *previous != mode) {
                output.delete_mode(previous);
            }
            if let Err(error) = state.observe_output(raywm_core::windows::OutputId::Nested, &output)
            {
                tracing::error!(%error, "Cannot update logical output");
            }
            state.request_window_size(size.to_logical(output.current_scale().integer_scale()));
            state.redraw = true;
            self.pending = false;
            tracing::info!(width = size.w, height = size.h, "Nested output resized");
        }
    }

    pub fn render(&mut self, state: &mut State) -> AppResult<()> {
        self.pending = false;
        let size = self.backend.window_size();
        if size.w <= 0 || size.h <= 0 {
            state.redraw = false;
            return Ok(());
        }
        let Some(output) = state.output.clone() else {
            return Ok(());
        };
        let (rendered, has_icon) = {
            let (renderer, mut framebuffer) = self.backend.bind()?;
            let icon_elements = drag_icon_elements(state, renderer, &output);
            // Buffer age zero intentionally gives a safe full redraw. The
            // tracker still caches render elements/textures; no GPU objects
            // are created by RayWM on idle iterations. Custom elements are
            // front-to-back, so the drag icon and its subsurfaces stay above
            // every space window and popup.
            let has_icon = !icon_elements.is_empty();
            let mut elements: Vec<_> = icon_elements
                .into_iter()
                .map(SceneElement::Window)
                .collect();
            elements.extend(window_elements(state, renderer, &output));
            let rendered = self
                .damage
                .render_output(
                    renderer,
                    &mut framebuffer,
                    0,
                    &elements,
                    [0.08, 0.10, 0.14, 1.0],
                )?
                .states;
            (rendered, has_icon)
        };
        self.backend.submit(Some(&[Rectangle::from_size(size)]))?;
        // Only after successful submission; only mapped windows are in Space.
        for window in state.space.elements() {
            window.with_surfaces(|surface, data| {
                update_surface_primary_scanout_output(
                    surface,
                    &output,
                    data,
                    &rendered,
                    |current, _, _, _| current,
                );
            });
            window.send_frame(
                &output,
                self.start.elapsed(),
                None,
                surface_primary_scanout_output,
            );
        }
        if has_icon {
            if let Some(icon) = state.selection.drag_icon.as_ref() {
                send_frames_surface_tree(
                    &icon.surface,
                    &output,
                    self.start.elapsed(),
                    None,
                    |_, states| {
                        states
                            .cached_state
                            .get::<SurfaceAttributes>()
                            .current()
                            .buffer
                            .is_some()
                            .then(|| output.clone())
                    },
                );
            }
        }
        state.redraw = false;
        state.space.refresh();
        Ok(())
    }
}

type SurfaceElement = WaylandSurfaceRenderElement<GlesRenderer>;

smithay::backend::renderer::element::render_elements! {
    SceneElement <= GlesRenderer>;
    Window = SurfaceElement,
    Cropped = CropRenderElement<SurfaceElement>,
}

/// Smithay renders actual buffer trees. A managed window may still hold an old
/// or oversized buffer, so clip its toplevel tree to its assigned rectangle.
/// Keep popup trees above the root and free to extend outside the tile.
fn window_elements(
    state: &State,
    renderer: &mut GlesRenderer,
    output: &Output,
) -> Vec<SceneElement> {
    let Some(area) = state.space.output_geometry(output) else {
        return Vec::new();
    };
    let factor = output.current_scale().fractional_scale();
    let scale = Scale::from(factor);
    let mut elements = Vec::new();
    for window in state.space.elements_for_output(output).rev() {
        let Some(view) = state.views.iter().find(|view| view.window == *window) else {
            continue;
        };
        if state.desktop.output_for(view.id) != Some(raywm_core::windows::OutputId::Nested) {
            continue;
        }
        let (Some(location), Some(top)) = (state.space.element_location(window), window.toplevel())
        else {
            continue;
        };
        let geometry = window.geometry();
        let offset = (location - geometry.loc - area.loc).to_physical_precise_round(factor);
        let Some(clip) = view.managed_box else {
            elements.extend(AsRenderElements::<GlesRenderer>::render_elements::<
                SceneElement,
            >(window, renderer, offset, scale, 1.0));
            continue;
        };
        for (popup, popup_offset) in PopupManager::popups_for_surface(top.wl_surface()) {
            let location = offset
                + (geometry.loc + popup_offset - popup.geometry().loc)
                    .to_physical_precise_round(factor);
            elements.extend(render_elements_from_surface_tree::<
                GlesRenderer,
                SceneElement,
            >(
                renderer,
                popup.wl_surface(),
                location,
                scale,
                1.0,
                Kind::Unspecified,
            ));
        }
        let mut clip = crate::shell::logical_rectangle(clip);
        clip.loc -= area.loc;
        let clip = clip.to_physical_precise_round(factor);
        elements.extend(
            render_elements_from_surface_tree::<GlesRenderer, SurfaceElement>(
                renderer,
                top.wl_surface(),
                offset,
                scale,
                1.0,
                Kind::Unspecified,
            )
            .into_iter()
            .filter_map(|element| CropRenderElement::from_element(element, scale, clip))
            .map(SceneElement::Cropped),
        );
    }
    elements
}

/// Position and import the drag icon into the ordinary GLES render pipeline.
/// Buffer scale/transform are handled by Smithay's surface render elements.
fn drag_icon_elements(
    state: &State,
    renderer: &mut GlesRenderer,
    output: &Output,
) -> Vec<WaylandSurfaceRenderElement<GlesRenderer>> {
    let Some(icon) = state
        .selection
        .drag_icon
        .as_ref()
        .filter(|icon| icon.surface.alive())
    else {
        return Vec::new();
    };
    let Some(output_geometry) = state.space.output_geometry(output) else {
        return Vec::new();
    };
    let Some(pointer) = state.seat.as_ref().and_then(|seat| seat.get_pointer()) else {
        return Vec::new();
    };
    let location = pointer.current_location();
    if !output_geometry.to_f64().contains(location) {
        return Vec::new();
    }
    let scale = Scale::from(output.current_scale().fractional_scale());
    let position: Point<i32, Physical> = (location - output_geometry.loc.to_f64()
        + icon.offset.to_f64())
    .to_physical(scale)
    .to_i32_round();
    AsRenderElements::<GlesRenderer>::render_elements(
        &SurfaceTree::from_surface(&icon.surface),
        renderer,
        position,
        scale,
        1.0,
    )
}

impl OutputHandler for State {}
delegate_output!(State);
