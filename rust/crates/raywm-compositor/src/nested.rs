//! One Winit window/output, using Smithay's EGL/GLES and desktop renderer.
//! Redraws are requested only for commits, resize, focus or host exposure.

use std::time::Instant;

use smithay::{
    backend::{
        renderer::{
            damage::OutputDamageTracker, element::surface::WaylandSurfaceRenderElement,
            gles::GlesRenderer,
        },
        winit::{self, WinitEventLoop, WinitGraphicsBackend},
    },
    delegate_output,
    desktop::utils::{surface_primary_scanout_output, update_surface_primary_scanout_output},
    output::{Mode, Output, PhysicalProperties, Subpixel},
    reexports::{
        wayland_server::DisplayHandle,
        winit::{dpi::LogicalSize, window::Window},
    },
    utils::{Physical, Rectangle, Size, Transform},
    wayland::output::{OutputHandler, OutputManagerState},
};

use crate::{state::State, Result};

pub struct Graphics {
    backend: WinitGraphicsBackend<GlesRenderer>,
    damage: OutputDamageTracker,
    pending: bool,
    start: Instant,
}

impl Graphics {
    pub fn new(state: &mut State, display: &DisplayHandle) -> Result<(Self, WinitEventLoop)> {
        // Winit connects using the incoming host environment. Never replace
        // WAYLAND_DISPLAY with the server's newly created client socket.
        let (backend, source) = winit::init_from_attributes::<GlesRenderer>(
            Window::default_attributes()
                .with_title("RayWM — Smithay Stage 2")
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
        state.space.map_output(&output, (0, 0));
        let mut seat = state.seat_state.new_wl_seat(display, "raywm-nested");
        seat.add_keyboard(Default::default(), 200, 25)?;
        seat.add_pointer();
        state.seat = Some(seat);
        state.output = Some(output.clone());
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
        if let Some(output) = &state.output {
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
            state.space.map_output(output, (0, 0));
            state.request_window_size(size.to_logical(1));
            state.space.refresh();
            state.redraw = true;
            self.pending = false;
            tracing::info!(width = size.w, height = size.h, "Nested output resized");
        }
    }

    pub fn render(&mut self, state: &mut State) -> Result<()> {
        self.pending = false;
        let size = self.backend.window_size();
        if size.w <= 0 || size.h <= 0 {
            state.redraw = false;
            return Ok(());
        }
        let Some(output) = state.output.clone() else {
            return Ok(());
        };
        let rendered = {
            let (renderer, mut framebuffer) = self.backend.bind()?;
            // Buffer age zero intentionally gives a safe full redraw. The
            // tracker still caches render elements/textures; no GPU objects
            // are created by RayWM on idle iterations.
            smithay::desktop::space::render_output::<
                _,
                WaylandSurfaceRenderElement<GlesRenderer>,
                _,
                _,
            >(
                &output,
                renderer,
                &mut framebuffer,
                1.0,
                0,
                [&state.space],
                &[],
                &mut self.damage,
                [0.08, 0.10, 0.14, 1.0],
            )?
            .states
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
        state.redraw = false;
        state.space.refresh();
        Ok(())
    }
}

impl OutputHandler for State {}
delegate_output!(State);
