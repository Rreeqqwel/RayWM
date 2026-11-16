//! Input-serial validation and a pointer grab containing only the stable window
//! ID. Logical operation/anchor state belongs to raywm-core, not this handle.

use crate::state::State;
use raywm_core::windows::{Edges, Position, SizeHints};
use smithay::{
    backend::input::ButtonState,
    input::{pointer::*, Seat},
    reexports::{
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::{
            protocol::{wl_seat::WlSeat, wl_surface::WlSurface},
            Resource,
        },
    },
    utils::{Logical, Point, Serial},
    wayland::{
        compositor::{get_parent, with_states},
        shell::xdg::{SurfaceCachedState, ToplevelSurface},
    },
};

impl State {
    pub fn start_operation(
        &mut self,
        top: ToplevelSurface,
        resource: WlSeat,
        serial: Serial,
        edges: Option<Edges>,
    ) {
        let Some(seat) = self.seat.clone() else {
            return;
        };
        if Seat::<Self>::from_resource(&resource).as_ref() != Some(&seat)
            || self.desktop.interaction_window().is_some()
            || self.popup_root.is_some()
        {
            return;
        }
        let Some(pointer) = seat.get_pointer() else {
            return;
        };
        if !pointer.has_grab(serial) {
            return;
        }
        let Some(start) = pointer.grab_start_data() else {
            return;
        };
        if !self.pressed_buttons.contains(&start.button) {
            return;
        }
        let Some((surface, _)) = &start.focus else {
            return;
        };
        let mut root = surface.clone();
        while let Some(parent) = get_parent(&root) {
            root = parent;
        }
        if root != *top.wl_surface() || !surface.id().same_client_as(&top.wl_surface().id()) {
            return;
        }
        let Some(id) = self.window_id(top.wl_surface()) else {
            return;
        };
        if self.desktop.focused() != Some(id) {
            return;
        }
        let point = Position {
            x: start.location.x.round() as i32,
            y: start.location.y.round() as i32,
        };
        let accepted = if let Some(edges) = edges {
            self.desktop.begin_resize(id, point, edges)
        } else {
            self.desktop.begin_move(id, point)
        };
        if !accepted {
            return;
        }
        pointer.set_grab(self, FloatingGrab { id, start }, serial, Focus::Clear);
        tracing::info!(
            window = id.get(),
            resize = edges.is_some(),
            "Interactive operation started"
        );
    }

    fn size_hints(&self) -> SizeHints {
        self.desktop
            .interaction_window()
            .and_then(|id| self.views.iter().find(|view| view.id == id))
            .and_then(|view| view.window.toplevel())
            .map(|top| {
                with_states(top.wl_surface(), |states| {
                    let mut cache = states.cached_state.get::<SurfaceCachedState>();
                    let state = cache.current();
                    SizeHints {
                        min: (
                            state.min_size.w.max(0) as u32,
                            state.min_size.h.max(0) as u32,
                        ),
                        max: (
                            state.max_size.w.max(0) as u32,
                            state.max_size.h.max(0) as u32,
                        ),
                    }
                })
            })
            .unwrap_or_default()
    }

    pub fn cancel_operation(&mut self) {
        if let Some(id) = self.desktop.interaction_window() {
            self.desktop.cancel_operation(id);
            self.reposition_popups();
            if let Some(view) = self.views.iter_mut().find(|view| view.id == id) {
                view.resize_flight = None;
                if let Some(top) = view.window.toplevel() {
                    top.with_pending_state(|state| {
                        state.states.unset(xdg_toplevel::State::Resizing)
                    });
                    top.send_pending_configure();
                }
            }
        }
    }
}

struct FloatingGrab {
    id: raywm_core::windows::WindowId,
    start: GrabStartData<State>,
}

macro_rules! gesture {
    ($method:ident,$event:ty) => {
        fn $method(
            &mut self,
            data: &mut State,
            handle: &mut PointerInnerHandle<'_, State>,
            event: &$event,
        ) {
            handle.$method(data, event);
        }
    };
}

impl PointerGrab<State> for FloatingGrab {
    fn motion(
        &mut self,
        data: &mut State,
        handle: &mut PointerInnerHandle<'_, State>,
        _: Option<(WlSurface, Point<f64, Logical>)>,
        event: &MotionEvent,
    ) {
        if data.desktop.interaction_window() != Some(self.id) {
            handle.unset_grab(self, data, event.serial, event.time, true);
            return;
        }
        handle.motion(data, None, event);
        data.desktop.drag_to(
            Position {
                x: event.location.x.round() as i32,
                y: event.location.y.round() as i32,
            },
            data.size_hints(),
        );
        data.sync_scene();
        data.redraw = true;
    }
    fn button(
        &mut self,
        data: &mut State,
        handle: &mut PointerInnerHandle<'_, State>,
        event: &ButtonEvent,
    ) {
        handle.button(data, event);
        if event.state == ButtonState::Released
            && !handle.current_pressed().contains(&self.start.button)
        {
            data.desktop.finish_interaction();
            // The interaction is already cleared, so unset() skips its own
            // pass; update popup constraints once the final parent geometry
            // is visible to the scene.
            data.reposition_popups();
            handle.unset_grab(self, data, event.serial, event.time, true);
        }
    }
    fn relative_motion(
        &mut self,
        data: &mut State,
        handle: &mut PointerInnerHandle<'_, State>,
        focus: Option<(WlSurface, Point<f64, Logical>)>,
        event: &RelativeMotionEvent,
    ) {
        handle.relative_motion(data, focus, event);
    }
    fn axis(
        &mut self,
        data: &mut State,
        handle: &mut PointerInnerHandle<'_, State>,
        event: AxisFrame,
    ) {
        handle.axis(data, event);
    }
    fn frame(&mut self, data: &mut State, handle: &mut PointerInnerHandle<'_, State>) {
        handle.frame(data);
    }
    gesture!(gesture_swipe_begin, GestureSwipeBeginEvent);
    gesture!(gesture_swipe_update, GestureSwipeUpdateEvent);
    gesture!(gesture_swipe_end, GestureSwipeEndEvent);
    gesture!(gesture_pinch_begin, GesturePinchBeginEvent);
    gesture!(gesture_pinch_update, GesturePinchUpdateEvent);
    gesture!(gesture_pinch_end, GesturePinchEndEvent);
    gesture!(gesture_hold_begin, GestureHoldBeginEvent);
    gesture!(gesture_hold_end, GestureHoldEndEvent);
    fn start_data(&self) -> &GrabStartData<State> {
        &self.start
    }
    fn unset(&mut self, data: &mut State) {
        if data.desktop.interaction_window() == Some(self.id) {
            data.desktop.finish_interaction();
            // Popup constraint updates are intentionally deferred to the end
            // of an interactive move/resize instead of one per pointer motion.
            data.reposition_popups();
        }
    }
}
