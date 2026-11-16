//! Seat focus and input forwarding. Only Winit events enter this module;
//! there is no libinput device, global shortcut or synthetic host input.

use raywm_core::windows::WindowId;
use smithay::{
    backend::input::{ButtonState, KeyState},
    input::{
        keyboard::FilterResult,
        pointer::{ButtonEvent, MotionEvent},
    },
    reexports::wayland_protocols::xdg::shell::server::xdg_toplevel,
    utils::SERIAL_COUNTER,
};

use crate::state::State;
use smithay::reexports::wayland_server::protocol::wl_surface::WlSurface;

impl State {
    pub fn focus_window(&mut self, id: Option<WindowId>) {
        if self.popup_root.is_some_and(|root| id != Some(root)) {
            return;
        }
        if self.desktop.focus(id) {
            self.sync_focus();
            self.redraw = true;
        }
    }

    pub fn sync_focus(&mut self) {
        self.sync_scene();
        let focused = self.desktop.focused();
        let mut target = None;
        for view in &self.views {
            let Some(top) = view.window.toplevel() else {
                continue;
            };
            let active = focused == Some(view.id);
            if active {
                target = Some(top.wl_surface().clone());
            }
            if self
                .desktop
                .get(view.id)
                .is_some_and(|window| window.mapped)
            {
                top.with_pending_state(|state| {
                    if active {
                        state.states.set(xdg_toplevel::State::Activated);
                    } else {
                        state.states.unset(xdg_toplevel::State::Activated);
                    }
                });
                top.send_pending_configure();
            }
        }
        if let Some(grab) = &self.popup_grab {
            target = grab.current_grab();
        }
        self.set_keyboard_focus(target, SERIAL_COUNTER.next_serial());
    }

    pub fn repair_pointer_focus(&mut self) {
        // A DnD grab intentionally has no pointer focus; never unset it here.
        if self.dnd_active
            || self.desktop.interaction_window().is_some()
            || self.popup_root.is_some()
        {
            return;
        }
        let time = smithay::utils::Clock::<smithay::utils::Monotonic>::new()
            .now()
            .as_millis();
        let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) else {
            return;
        };
        let valid = pointer.current_focus().is_some_and(|surface| {
            self.surface_window(&surface)
                .and_then(|id| self.desktop.get(id))
                .is_some_and(|window| window.mapped)
        });
        if !valid {
            pointer.unset_grab(self, SERIAL_COUNTER.next_serial(), time);
            let location = pointer.current_location();
            pointer.motion(
                self,
                None,
                &MotionEvent {
                    location,
                    serial: SERIAL_COUNTER.next_serial(),
                    time,
                },
            );
            // Drop native held-button state without forwarding a release to
            // another surface. Physical releases finish the orphaned interaction.
            if !self.pointer_blocked {
                for button in self.pressed_buttons.clone() {
                    pointer.button(
                        self,
                        &ButtonEvent {
                            button,
                            state: ButtonState::Released,
                            serial: SERIAL_COUNTER.next_serial(),
                            time,
                        },
                    );
                }
                self.pointer_blocked = !self.pressed_buttons.is_empty();
            }
            // A destroyed focus surface may reveal another window under the
            // stationary pointer. Re-establish pointer focus so the next click
            // targets the visible window instead of a null focus.
            let under = if self.pointer_blocked {
                None
            } else {
                self.surface_under(location)
            };
            pointer.motion(
                self,
                under,
                &MotionEvent {
                    location,
                    serial: SERIAL_COUNTER.next_serial(),
                    time,
                },
            );
            pointer.frame(self);
        }
    }

    pub fn clear_input(&mut self) {
        self.cancel_operation();
        self.end_popup_grab();
        self.key_grant = None;
        let time = smithay::utils::Clock::<smithay::utils::Monotonic>::new()
            .now()
            .as_millis();
        if let Some(keyboard) = self.seat.as_ref().and_then(|seat| seat.get_keyboard()) {
            for key in keyboard.pressed_keys() {
                keyboard.input::<(), _>(
                    self,
                    key,
                    KeyState::Released,
                    SERIAL_COUNTER.next_serial(),
                    time,
                    |_, _, _| FilterResult::Forward,
                );
            }
        }
        if let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) {
            for button in std::mem::take(&mut self.pressed_buttons) {
                pointer.button(
                    self,
                    &ButtonEvent {
                        button,
                        state: ButtonState::Released,
                        serial: SERIAL_COUNTER.next_serial(),
                        time,
                    },
                );
            }
            pointer.unset_grab(self, SERIAL_COUNTER.next_serial(), time);
            pointer.motion(
                self,
                None,
                &MotionEvent {
                    location: pointer.current_location(),
                    serial: SERIAL_COUNTER.next_serial(),
                    time,
                },
            );
            pointer.frame(self);
        }
        self.focus_window(None);
        self.pointer_blocked = false;
    }

    #[cfg(feature = "winit")]
    pub fn host_focus(&mut self, focused: bool) {
        tracing::info!(focused, "Host focus changed");
        self.host_focused = focused;
        if focused {
            let target = self.desktop.topmost();
            self.focus_window(target);
        } else {
            self.clear_input();
        }
        self.redraw = true;
    }

    fn surface_under(
        &self,
        position: smithay::utils::Point<f64, smithay::utils::Logical>,
    ) -> Option<(
        WlSurface,
        smithay::utils::Point<f64, smithay::utils::Logical>,
    )> {
        use smithay::desktop::WindowSurfaceType;
        self.space
            .element_under(position)
            .and_then(|(window, location)| {
                window
                    .surface_under(position - location.to_f64(), WindowSurfaceType::ALL)
                    .map(|(surface, point)| (surface, (point + location).to_f64()))
            })
    }

    #[cfg(feature = "winit")]
    pub fn process_input(
        &mut self,
        event: smithay::backend::input::InputEvent<smithay::backend::winit::WinitInput>,
    ) {
        use smithay::backend::input::{
            AbsolutePositionEvent, Axis, AxisSource, Event, InputEvent, KeyboardKeyEvent,
            PointerAxisEvent, PointerButtonEvent,
        };
        use smithay::input::pointer::AxisFrame;
        match event {
            InputEvent::Keyboard { event } => {
                if let Some(keyboard) = self.seat.as_ref().and_then(|seat| seat.get_keyboard()) {
                    let serial = SERIAL_COUNTER.next_serial();
                    if event.state() == KeyState::Pressed {
                        self.key_grant = keyboard
                            .current_focus()
                            .map(|target| (serial, target, std::time::Instant::now()));
                    }
                    keyboard.input::<(), _>(
                        self,
                        event.key_code(),
                        event.state(),
                        serial,
                        event.time_msec(),
                        |_, _, _| FilterResult::Forward,
                    );
                    let focus = keyboard.current_focus();
                    self.note_selection_serial(serial, focus.as_ref());
                }
            }
            InputEvent::PointerMotionAbsolute { event } => {
                let Some(output) = &self.output else { return };
                let Some(geometry) = self.space.output_geometry(output) else {
                    return;
                };
                let position = event.position_transformed(geometry.size);
                if let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) {
                    let under = if self.pointer_blocked {
                        None
                    } else {
                        self.surface_under(position)
                    };
                    let serial = SERIAL_COUNTER.next_serial();
                    let previous = pointer.current_focus();
                    pointer.motion(
                        self,
                        under,
                        &MotionEvent {
                            location: position,
                            serial,
                            time: event.time_msec(),
                        },
                    );
                    if pointer.current_focus() != previous {
                        let focus = pointer.current_focus();
                        self.note_selection_serial(serial, focus.as_ref());
                    }
                    pointer.frame(self);
                    if self.selection.drag_icon.is_some() {
                        // The compositor draws the icon; Winit only draws its
                        // own cursor. No idle redraw is added without a drag.
                        self.redraw = true;
                    }
                }
            }
            InputEvent::PointerButton { event } => {
                let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) else {
                    return;
                };
                let button = event.button_code();
                if event.state() == ButtonState::Pressed {
                    if !self.pressed_buttons.contains(&button) {
                        self.pressed_buttons.push(button);
                    }
                    if !pointer.is_grabbed() && !self.pointer_blocked {
                        let target = self
                            .space
                            .element_under(pointer.current_location())
                            .map(|(window, _)| window.clone());
                        let id = target
                            .as_ref()
                            .and_then(|window| window.toplevel())
                            .and_then(|top| self.window_id(top.wl_surface()));
                        self.focus_window(id);
                    }
                } else {
                    self.pressed_buttons.retain(|held| *held != button);
                }
                if self.pointer_blocked {
                    if self.pressed_buttons.is_empty() {
                        self.pointer_blocked = false;
                        let location = pointer.current_location();
                        pointer.motion(
                            self,
                            self.surface_under(location),
                            &MotionEvent {
                                location,
                                serial: SERIAL_COUNTER.next_serial(),
                                time: event.time_msec(),
                            },
                        );
                        pointer.frame(self);
                    }
                    return;
                }
                let serial = SERIAL_COUNTER.next_serial();
                pointer.button(
                    self,
                    &ButtonEvent {
                        button,
                        state: event.state(),
                        serial,
                        time: event.time_msec(),
                    },
                );
                let focus = pointer.current_focus();
                self.note_selection_serial(serial, focus.as_ref());
                if self.pressed_buttons.is_empty() && !pointer.is_grabbed() {
                    let location = pointer.current_location();
                    pointer.motion(
                        self,
                        self.surface_under(location),
                        &MotionEvent {
                            location,
                            serial: SERIAL_COUNTER.next_serial(),
                            time: event.time_msec(),
                        },
                    );
                }
                pointer.frame(self);
            }
            InputEvent::PointerAxis { event } => {
                if let Some(pointer) = self.seat.as_ref().and_then(|seat| seat.get_pointer()) {
                    let mut frame = AxisFrame::new(event.time_msec()).source(event.source());
                    for axis in [Axis::Horizontal, Axis::Vertical] {
                        let amount = event.amount(axis).unwrap_or_else(|| {
                            event.amount_v120(axis).unwrap_or(0.0) * 15.0 / 120.0
                        });
                        if amount != 0.0 {
                            frame = frame.value(axis, amount);
                        }
                        if let Some(discrete) = event.amount_v120(axis) {
                            frame = frame.v120(axis, discrete as i32);
                        }
                        if event.source() == AxisSource::Finger && event.amount(axis) == Some(0.0) {
                            frame = frame.stop(axis);
                        }
                    }
                    pointer.axis(self, frame);
                    pointer.frame(self);
                }
            }
            _ => {}
        }
    }
}
