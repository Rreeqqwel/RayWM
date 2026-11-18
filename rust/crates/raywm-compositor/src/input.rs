//! Seat focus, compositor shortcuts and client input forwarding.

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
        let _ = self.execute_command(raywm_core::commands::Command::FocusWindow(id));
    }

    pub fn sync_focus(&mut self) {
        self.sync_scene();
        let focused = self
            .desktop
            .focused()
            .filter(|_| self.host_focused || self.seat.is_none());
        let mut target = None;
        for view in &mut self.views {
            let Some(top) = view.window.toplevel() else {
                continue;
            };
            let active = focused == Some(view.id) && self.desktop.visible(view.id);
            if active {
                target = Some(top.wl_surface().clone());
            }
            if self
                .desktop
                .get(view.id)
                .is_some_and(|window| window.mapped())
            {
                top.with_pending_state(|state| {
                    if active {
                        state.states.set(xdg_toplevel::State::Activated);
                    } else {
                        state.states.unset(xdg_toplevel::State::Activated);
                    }
                });
            }
            view.send_focus_configure();
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
                .is_some_and(|id| self.desktop.visible(id))
        });
        if !valid && (pointer.current_focus().is_some() || pointer.is_grabbed()) {
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
        }
        // Layout changes can move a tile under a stationary pointer.
        if !pointer.is_grabbed() && !self.pointer_blocked {
            let location = pointer.current_location();
            let under = self.surface_under(location);
            if under.as_ref().map(|(surface, _)| surface) != pointer.current_focus().as_ref()
                || valid
            {
                let serial = SERIAL_COUNTER.next_serial();
                let previous = pointer.current_focus();
                pointer.motion(
                    self,
                    under,
                    &MotionEvent {
                        location,
                        serial,
                        time,
                    },
                );
                if pointer.current_focus() != previous {
                    let focus = pointer.current_focus();
                    self.note_selection_serial(serial, focus.as_ref());
                }
            }
            pointer.frame(self);
        }
    }

    pub fn clear_input(&mut self) {
        self.cancel_operation();
        self.end_popup_grab();
        self.key_grant = None;
        self.pointer_grant = None;
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
                    |state, _, _| {
                        if state.shortcut_keys.remove(&key) {
                            FilterResult::Intercept(())
                        } else {
                            FilterResult::Forward
                        }
                    },
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
            let target = self.desktop.focused().or_else(|| self.desktop.topmost());
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
        use smithay::desktop::WindowSurfaceType as SurfaceType;
        self.space.elements().rev().find_map(|window| {
            let view = self.views.iter().find(|view| view.window == *window)?;
            if let Some(output) = self
                .desktop
                .output_for(view.id)
                .and_then(|id| self.desktop.output(id))
            {
                if !crate::shell::logical_rectangle(output.geometry)
                    .to_f64()
                    .contains(position)
                {
                    return None;
                }
            }
            let location = self.space.element_location(window)? - window.geometry().loc;
            let local = position - location.to_f64();
            let inside = view.managed_box.is_none_or(|geometry| {
                crate::shell::logical_rectangle(geometry)
                    .to_f64()
                    .contains(position)
            });
            let surfaces = if inside {
                SurfaceType::ALL
            } else {
                SurfaceType::POPUP | SurfaceType::SUBSURFACE
            };
            window
                .surface_under(local, surfaces)
                .map(|(surface, point)| (surface, (point + location).to_f64()))
        })
    }

    #[cfg(feature = "winit")]
    fn key_event(
        &mut self,
        keyboard: &smithay::input::keyboard::KeyboardHandle<Self>,
        code: smithay::backend::input::Keycode,
        event: KeyState,
        serial: smithay::utils::Serial,
        time: u32,
    ) {
        let (command, mods_changed) =
            keyboard.input_intercept(self, code, event, |state, mods, key| {
                if event != KeyState::Pressed || !mods.logo || mods.ctrl || mods.alt {
                    return None;
                }
                key.raw_syms()
                    .first()
                    .and_then(|sym| state.shortcut(sym.raw(), mods.shift))
                    .filter(|command| {
                        if state.popup_root.is_some() {
                            crate::policy::is_workspace_switch(command)
                        } else {
                            !keyboard.is_grabbed()
                        }
                    })
            });
        if event == KeyState::Released && self.shortcut_keys.remove(&code) {
            return;
        }
        if self.shortcut_keys.contains(&code) {
            return;
        }
        if let Some(command) = command {
            self.shortcut_keys.insert(code);
            match self.execute_command(command) {
                Ok(_) => {}
                Err(error) => tracing::debug!(%error, "Shortcut command rejected"),
            }
            return;
        }
        if event == KeyState::Pressed {
            self.key_grant = keyboard
                .current_focus()
                .map(|target| (serial, target, std::time::Instant::now()));
        }
        keyboard.input_forward(self, code, event, serial, time, mods_changed);
        let focus = keyboard.current_focus();
        self.note_selection_serial(serial, focus.as_ref());
    }

    #[cfg(feature = "winit")]
    fn shortcut(&self, symbol: u32, shift: bool) -> Option<raywm_core::commands::Command> {
        use raywm_core::commands::Command;
        use smithay::input::keyboard::keysyms::{
            KEY_Page_Down as PAGE_DOWN, KEY_Page_Up as PAGE_UP, KEY_f as F, KEY_j as J, KEY_k as K,
            KEY_m as M, KEY_space as SPACE, KEY_1, KEY_9,
        };
        let focused = self.desktop.focused();
        let workspace = self.desktop.active_workspace();
        Some(match (symbol, shift) {
            (KEY_1..=KEY_9, false) => Command::ActivateWorkspace(
                self.desktop
                    .workspace_number((symbol - KEY_1 + 1) as usize)?,
            ),
            (KEY_1..=KEY_9, true) => Command::MoveWindowToWorkspace {
                id: focused?,
                workspace: self
                    .desktop
                    .workspace_number((symbol - KEY_1 + 1) as usize)?,
            },
            (J, false) => Command::FocusNext,
            (K, false) => Command::FocusPrevious,
            (J | K, true) => Command::ReorderWindow {
                id: focused?,
                forward: symbol == J,
            },
            (F, false) => Command::ToggleFullscreen(focused?),
            (M, false) => Command::ToggleMaximized(focused?),
            (SPACE, false) => Command::CycleLayout(workspace),
            (SPACE, true) => Command::ToggleFloating(focused?),
            (PAGE_DOWN, false) => Command::NextWorkspace,
            (PAGE_UP, false) => Command::PreviousWorkspace,
            _ => return None,
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
                    self.key_event(
                        &keyboard,
                        event.key_code(),
                        event.state(),
                        serial,
                        event.time_msec(),
                    );
                }
            }
            InputEvent::PointerMotionAbsolute { event } => {
                let Some(output) = &self.output else { return };
                let Some(geometry) = self.space.output_geometry(output) else {
                    return;
                };
                let position = event.position_transformed(geometry.size) + geometry.loc.to_f64();
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
                        let id = self
                            .surface_under(pointer.current_location())
                            .and_then(|(surface, _)| self.surface_window(&surface));
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
                if event.state() == ButtonState::Pressed {
                    // Toolkits may dispatch the popup request after the physical
                    // release. Keep only the latest press actually delivered to
                    // a surface; focus transitions invalidate this one-shot grant.
                    self.pointer_grant = focus
                        .as_ref()
                        .map(|surface| (serial, surface.clone(), std::time::Instant::now()));
                }
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
