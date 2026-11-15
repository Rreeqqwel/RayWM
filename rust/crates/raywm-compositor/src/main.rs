//! Experimental headless/XDG server and nested Winit compositor.

mod input;
#[cfg(feature = "winit")]
mod nested;
mod shell;
mod state;

use std::{
    error::Error,
    io,
    os::{fd::AsFd, unix::fs::MetadataExt},
    path::PathBuf,
    process::ExitCode,
    sync::Arc,
};

use calloop::{
    generic::Generic,
    signals::{Signal, Signals},
    EventLoop, Interest, Mode, PostAction,
};
use raywm_core::{HeadlessConfig, SocketName};
use smithay::{
    reexports::wayland_server::{backend::DisconnectReason, Display},
    wayland::socket::ListeningSocketSource,
};

use state::{ClientState, State};

type Result<T> = std::result::Result<T, Box<dyn Error>>;

struct Runtime {
    display: Display<State>,
    state: State,
    running: bool,
    #[cfg(feature = "winit")]
    graphics: Option<nested::Graphics>,
    failure: Option<String>,
}

#[derive(Default)]
struct Options {
    socket: HeadlessConfig,
    winit: bool,
}

fn main() -> ExitCode {
    tracing_subscriber::fmt()
        .with_target(false)
        .with_writer(io::stderr)
        .init();
    match arguments().and_then(|config| match config {
        Some(config) => run(config),
        None => Ok(()),
    }) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            tracing::error!(%error, "raywm-smithay failed");
            ExitCode::FAILURE
        }
    }
}

fn arguments() -> Result<Option<Options>> {
    let mut config = Options::default();
    let mut backend_seen = false;
    let mut args = std::env::args_os().skip(1);
    while let Some(arg) = args.next() {
        match arg.to_str() {
            Some("--help" | "-h") => {
                println!("Usage: raywm-smithay [--backend headless|winit] [--socket NAME]\n\nExperimental Wayland compositor. Default backend: headless.\nWinit opens one nested window; headless has no rendering or input.\nRequires an owned mode-0700 XDG_RUNTIME_DIR. SIGINT/SIGTERM stop cleanly.");
                return Ok(None);
            }
            Some("--socket") if config.socket.socket_name.is_none() => {
                let name = args.next().ok_or("--socket requires a name")?;
                let name = name
                    .into_string()
                    .map_err(|_| "socket name must be ASCII")?;
                config.socket.socket_name = Some(SocketName::new(name)?);
            }
            Some("--backend") if !backend_seen => {
                backend_seen = true;
                let backend = args.next().ok_or("--backend requires headless or winit")?;
                config.winit = match backend.to_str() {
                    Some("headless") => false,
                    Some("winit") => true,
                    _ => return Err("--backend must be headless or winit".into()),
                };
            }
            _ => return Err(format!("unknown or repeated argument {arg:?}; use --help").into()),
        }
    }
    Ok(Some(config))
}

fn runtime_directory() -> Result<PathBuf> {
    let path = PathBuf::from(
        std::env::var_os("XDG_RUNTIME_DIR")
            .ok_or("XDG_RUNTIME_DIR must name a private directory")?,
    );
    let metadata = std::fs::symlink_metadata(&path)?;
    if !path.is_absolute()
        || !metadata.is_dir()
        || metadata.uid() != rustix::process::getuid().as_raw()
        || metadata.mode() & 0o777 != 0o700
    {
        return Err(
            "XDG_RUNTIME_DIR must be an absolute, owned directory with mode 0700 (no symlink)"
                .into(),
        );
    }
    Ok(path)
}

fn run(config: Options) -> Result<()> {
    #[cfg(not(feature = "winit"))]
    if config.winit {
        return Err("Winit backend not compiled; rebuild with --features winit".into());
    }
    let runtime_dir = runtime_directory()?;
    let mut event_loop: EventLoop<Runtime> = EventLoop::try_new()?;
    let handle = event_loop.handle();

    // Set up signalfd before initializing any future thread-producing backend.
    // Stage 1 is single-threaded and never starts a session or spawns children.
    let signals = Signals::new(&[Signal::SIGINT, Signal::SIGTERM])?;
    handle
        .insert_source(signals, |event, _, runtime| {
            tracing::info!(signal = ?event.signal(), "Shutdown requested");
            runtime.running = false;
        })
        .map_err(|error| io::Error::other(format!("register signals: {}", error.error)))?;

    let display = Display::<State>::new()?;
    let state = State::new(&display.handle());
    // Poll an owned duplicate; keep Display in Runtime so dispatch needs no
    // unsafe Generic::get_mut and the registered FD cannot outlive its owner.
    let display_fd = display.as_fd().try_clone_to_owned()?;
    handle
        .insert_source(
            Generic::new(display_fd, Interest::READ, Mode::Level),
            |_, _, runtime| {
                runtime.display.dispatch_clients(&mut runtime.state)?;
                Ok(PostAction::Continue)
            },
        )
        .map_err(|error| io::Error::other(format!("register display: {}", error.error)))?;

    let socket = match config.socket.socket_name {
        Some(name) => ListeningSocketSource::with_name(name.as_str())?,
        None => ListeningSocketSource::new_auto()?,
    };
    let socket_name = socket.socket_name().to_owned();
    let listener = handle
        .insert_source(socket, |stream, _, runtime| {
            if let Err(error) = runtime
                .display
                .handle()
                .insert_client(stream, Arc::new(ClientState::default()))
            {
                // A failed admission drops this stream; other clients survive.
                tracing::warn!(%error, "Cannot accept Wayland client");
            }
        })
        .map_err(|error| io::Error::other(format!("register socket: {}", error.error)))?;

    let mut runtime = Runtime {
        display,
        state,
        running: true,
        #[cfg(feature = "winit")]
        graphics: None,
        failure: None,
    };

    #[cfg(feature = "winit")]
    if config.winit {
        let (graphics, source) =
            nested::Graphics::new(&mut runtime.state, &runtime.display.handle())?;
        runtime.graphics = Some(graphics);
        handle
            .insert_source(source, |event, _, runtime| {
                if let Err(error) = runtime.winit_event(event) {
                    runtime.failure = Some(error.to_string());
                    runtime.running = false;
                }
            })
            .map_err(|error| {
                io::Error::other(format!("register Winit backend: {}", error.error))
            })?;
    }
    if config.winit {
        tracing::info!(socket = ?runtime_dir.join(&socket_name), "Nested Wayland server ready");
    } else {
        tracing::info!(socket = ?runtime_dir.join(&socket_name), "Headless Wayland server ready (XDG lifecycle only; no renderer or input)");
    }

    let result = (|| -> Result<()> {
        while runtime.running {
            #[cfg(feature = "winit")]
            if let Some(graphics) = &mut runtime.graphics {
                graphics.request_redraw(&mut runtime.state);
            }
            // Sleep until a socket, protocol request or signal is ready. No
            // frame timer, busy polling or synchronous plugin work is present.
            event_loop.dispatch(None, &mut runtime)?;
            runtime.display.flush_clients()?;
        }
        if let Some(error) = runtime.failure.take() {
            return Err(error.into());
        }
        Ok(())
    })();

    // Stop admission first, disconnect clients and run their destroy handlers
    // while State and the protocol globals still exist. Drop poll sources
    // before Display; ListeningSocket's Drop removes its socket and lockfile.
    handle.remove(listener);
    runtime.state.clear_input();
    let backend = runtime.display.handle().backend_handle();
    let mut clients = Vec::new();
    backend.with_all_clients(|id| clients.push(id));
    for client in clients {
        backend.kill_client(client, DisconnectReason::ConnectionClosed);
    }
    let cleanup = runtime.display.dispatch_clients(&mut runtime.state);
    runtime.state.output_manager.take();
    drop(backend);
    // Client destruction hooks have now released their GPU resources. Keep
    // Winit's event source/display alive while dropping the EGL renderer.
    #[cfg(feature = "winit")]
    drop(runtime.graphics.take());
    drop(handle);
    drop(event_loop);
    result?;
    cleanup?;
    if config.winit {
        tracing::info!("Nested Wayland server stopped");
    } else {
        tracing::info!("Headless Wayland server stopped");
    }
    Ok(())
}

#[cfg(feature = "winit")]
impl Runtime {
    fn winit_event(&mut self, event: smithay::backend::winit::WinitEvent) -> Result<()> {
        use smithay::backend::winit::WinitEvent;
        match event {
            WinitEvent::CloseRequested => self.running = false,
            WinitEvent::Focus(focused) => self.state.host_focus(focused),
            WinitEvent::Input(event) => self.state.process_input(event),
            WinitEvent::Resized { size, .. } => {
                if let Some(graphics) = &mut self.graphics {
                    graphics.resize(&mut self.state, size);
                }
            }
            WinitEvent::Redraw => {
                if let Some(graphics) = &mut self.graphics {
                    graphics.render(&mut self.state)?;
                }
            }
        }
        Ok(())
    }
}
