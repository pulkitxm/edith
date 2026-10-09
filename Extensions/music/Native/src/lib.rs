use clap::Parser;
use librespot::{
    connect::{ConnectConfig, LoadRequest, LoadRequestOptions, PlayingTrack, Spirc},
    core::{authentication::Credentials, config::SessionConfig, session::Session},
    metadata::audio::UniqueFields,
    playback::{
        audio_backend,
        config::{AudioFormat, PlayerConfig},
        mixer::{self, MixerConfig},
        player::{Player, PlayerEvent},
    },
    protocol::authentication::AuthenticationType,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::ffi::{CStr, c_char, c_void};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};
use std::thread;
use tokio::sync::{mpsc, oneshot};

#[derive(Parser)]
struct Arguments {
    service: String,
    name: String,
    #[arg(long, conflicts_with = "forget")]
    resume: bool,
    #[arg(long)]
    forget: bool,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
enum Command {
    Play {
        uri: String,
        index: Option<u32>,
    },
    Toggle,
    Pause,
    Next,
    Previous,
    Seek {
        milliseconds: u32,
    },
    Volume {
        value: f64,
    },
    AuthorizeLibrary,
    Catalog {
        #[serde(flatten)]
        request: catalog::Request,
    },
    QueueAdd {
        uri: String,
    },
    Shuffle {
        value: bool,
    },
    Repeat {
        mode: String,
    },
    SetSaved {
        uri: String,
        saved: bool,
    },
    CreatePlaylist {
        name: String,
    },
    Disconnect,
}

type EventCallback = unsafe extern "C" fn(*const u8, usize, *mut c_void);

#[derive(Clone, Copy)]
struct EventSink {
    callback: EventCallback,
    context: usize,
}

static EVENT_SINK: Mutex<Option<EventSink>> = Mutex::new(None);
static ACTIVE: AtomicBool = AtomicBool::new(false);

fn emit(value: Value) {
    let Ok(sink) = EVENT_SINK.lock() else { return };
    let Some(sink) = *sink else { return };
    let Ok(data) = serde_json::to_vec(&value) else {
        return;
    };
    unsafe { (sink.callback)(data.as_ptr(), data.len(), sink.context as *mut c_void) };
}

struct PlayerHandle {
    commands: mpsc::UnboundedSender<String>,
    cancellation: Option<oneshot::Sender<()>>,
    thread: Option<thread::JoinHandle<()>>,
}

fn launch(
    service: String,
    name: String,
    mode: Option<String>,
    sink: EventSink,
    session: impl FnOnce(
        String,
        String,
        Option<String>,
        mpsc::UnboundedReceiver<String>,
        oneshot::Receiver<()>,
    ) + Send
    + 'static,
) -> Option<Box<PlayerHandle>> {
    if ACTIVE
        .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .is_err()
    {
        return None;
    }
    *EVENT_SINK.lock().ok()? = Some(sink);
    let (commands, receiver) = mpsc::unbounded_channel();
    let (cancellation, cancelled) = oneshot::channel();
    let thread = thread::Builder::new()
        .name("music.spotify".into())
        .spawn(move || {
            let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                session(service, name, mode, receiver, cancelled)
            }));
            if outcome.is_err() {
                emit(
                    json!({"event":"error", "message":"The Spotify player stopped unexpectedly."}),
                );
            }
        });
    match thread {
        Ok(thread) => Some(Box::new(PlayerHandle {
            commands,
            cancellation: Some(cancellation),
            thread: Some(thread),
        })),
        Err(_) => {
            *EVENT_SINK.lock().ok()? = None;
            ACTIVE.store(false, Ordering::Release);
            None
        }
    }
}

impl Drop for PlayerHandle {
    fn drop(&mut self) {
        if let Some(cancellation) = self.cancellation.take() {
            let _ = cancellation.send(());
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
        if let Ok(mut sink) = EVENT_SINK.lock() {
            *sink = None;
        }
        ACTIVE.store(false, Ordering::Release);
    }
}

unsafe fn bounded_text(value: *const c_char, maximum: usize) -> Option<String> {
    if value.is_null() {
        return None;
    }
    let bytes = unsafe { CStr::from_ptr(value) }.to_bytes();
    if bytes.is_empty() || bytes.len() > maximum {
        return None;
    }
    std::str::from_utf8(bytes).ok().map(String::from)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn edith_music_player_start(
    service: *const c_char,
    name: *const c_char,
    mode: i32,
    callback: Option<EventCallback>,
    context: *mut c_void,
) -> *mut c_void {
    let Some(service) = (unsafe { bounded_text(service, 256) }) else {
        return std::ptr::null_mut();
    };
    let Some(name) = (unsafe { bounded_text(name, 128) }) else {
        return std::ptr::null_mut();
    };
    let Some(callback) = callback else {
        return std::ptr::null_mut();
    };
    let mode = match mode {
        0 => None,
        1 => Some("--resume".into()),
        2 => Some("--forget".into()),
        _ => return std::ptr::null_mut(),
    };
    let handle = launch(
        service,
        name,
        mode,
        EventSink {
            callback,
            context: context as usize,
        },
        |service, name, mode, receiver, mut cancelled| {
            let Ok(runtime) = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .worker_threads(2)
                .build()
            else {
                return;
            };
            runtime.block_on(async {
            tokio::select! {
                result = run(&service, &name, mode.as_deref(), receiver) => {
                    if result.is_err() { emit(json!({"event":"error", "message":"Spotify could not connect. Check your internet connection and Premium account, or disconnect and sign in again."})); }
                }
                _ = &mut cancelled => {}
            }
        });
            runtime.shutdown_timeout(std::time::Duration::from_millis(250));
            emit(json!({"event":"terminated"}));
        },
    );
    handle.map_or(std::ptr::null_mut(), |handle| Box::into_raw(handle).cast())
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn edith_music_player_send(
    handle: *mut c_void,
    data: *const u8,
    length: usize,
) -> bool {
    if handle.is_null() || data.is_null() || length == 0 || length > 4096 {
        return false;
    }
    let Ok(command) = std::str::from_utf8(unsafe { std::slice::from_raw_parts(data, length) })
    else {
        return false;
    };
    if serde_json::from_str::<Command>(command).is_err() {
        return false;
    }
    unsafe { &*handle.cast::<PlayerHandle>() }
        .commands
        .send(command.into())
        .is_ok()
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn edith_music_player_stop(handle: *mut c_void) {
    if !handle.is_null() {
        drop(unsafe { Box::from_raw(handle.cast::<PlayerHandle>()) });
    }
}

fn valid_uri(uri: &str) -> bool {
    catalog::catalog_uri(uri)
}

fn execute(spirc: &Spirc, command: Command) -> Result<bool, librespot::core::Error> {
    match command {
        Command::Play { uri, index } => {
            if !valid_uri(&uri) {
                return Err(librespot::core::Error::invalid_argument(
                    "invalid Spotify link",
                ));
            }
            spirc.activate()?;
            spirc.load(LoadRequest::from_context_uri(
                uri,
                LoadRequestOptions {
                    start_playing: true,
                    playing_track: index.map(PlayingTrack::Index),
                    ..Default::default()
                },
            ))?;
        }
        Command::Toggle => spirc.play_pause()?,
        Command::Pause => spirc.pause()?,
        Command::Next => spirc.next()?,
        Command::Previous => spirc.prev()?,
        Command::Seek { milliseconds } => spirc.set_position_ms(milliseconds)?,
        Command::Volume { value } => {
            if !value.is_finite() {
                return Err(librespot::core::Error::invalid_argument("invalid volume"));
            }
            spirc.set_volume((value.clamp(0.0, 1.0) * u16::MAX as f64) as u16)?;
        }
        Command::Shuffle { value } => spirc.shuffle(value)?,
        Command::Repeat { mode } => match mode.as_str() {
            "off" => {
                spirc.repeat(false)?;
                spirc.repeat_track(false)?;
            }
            "context" => {
                spirc.repeat_track(false)?;
                spirc.repeat(true)?;
            }
            "track" => spirc.repeat_track(true)?,
            _ => {
                return Err(librespot::core::Error::invalid_argument(
                    "invalid repeat mode",
                ));
            }
        },
        Command::Disconnect => {
            spirc.shutdown()?;
            return Ok(false);
        }
        _ => {
            return Err(librespot::core::Error::invalid_argument(
                "invalid playback command",
            ));
        }
    }
    Ok(true)
}

async fn run(
    service: &str,
    name: &str,
    mode: Option<&str>,
    mut commands: mpsc::UnboundedReceiver<String>,
) -> Result<(), Box<dyn std::error::Error>> {
    let entry = keyring::Entry::new(service, "spotify")?;
    if mode == Some("--forget") {
        catalog::Library::forget(service)?;
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => return Ok(()),
            Err(error) => return Err(error.into()),
        }
    }
    let config = SessionConfig::default();
    let saved = match entry.get_password() {
        Ok(value) => Some(serde_json::from_str::<Credentials>(&value)?),
        Err(keyring::Error::NoEntry) => None,
        Err(error) => return Err(error.into()),
    };
    let credentials = match saved {
        Some(credentials) => credentials,
        None => {
            if mode == Some("--resume") {
                return Err("sign-in is required".into());
            }
            emit(json!({"event": "authorizing"}));
            let client_id = config.client_id.clone();
            let token = tokio::task::spawn_blocking(move || {
                librespot_oauth::OAuthClientBuilder::new(
                    &client_id,
                    "http://127.0.0.1:8898/login",
                    vec!["streaming"],
                )
                .open_in_browser()
                .build()?
                .get_access_token()
            })
            .await??;
            Credentials::with_access_token(token.access_token)
        }
    };
    let session = Session::new(config, None);
    let sink =
        audio_backend::find(Some("rodio".into())).ok_or("the audio output is unavailable")?;
    let mixer = mixer::find(None).ok_or("the audio mixer is unavailable")?(MixerConfig::default())?;
    let player = Player::new(
        PlayerConfig {
            position_update_interval: Some(std::time::Duration::from_secs(1)),
            ..PlayerConfig::default()
        },
        session.clone(),
        mixer.get_soft_volume(),
        move || sink(None, AudioFormat::default()),
    );
    let mut events = player.get_player_event_channel();
    let connect = ConnectConfig {
        name: name.into(),
        ..ConnectConfig::default()
    };
    let (spirc, connection) =
        match Spirc::new(connect, session.clone(), credentials, player, mixer).await {
            Ok(value) => value,
            Err(error) => {
                if error.kind == librespot::core::error::ErrorKind::Unauthenticated {
                    let _ = entry.delete_credential();
                }
                return Err(error.into());
            }
        };
    let reusable = Credentials {
        username: Some(session.username()),
        auth_type: AuthenticationType::AUTHENTICATION_STORED_SPOTIFY_CREDENTIALS,
        auth_data: session.auth_data(),
    };
    entry.set_password(&serde_json::to_string(&reusable)?)?;
    emit(json!({"event": "connected", "account": session.username()}));
    let library = catalog::Library::new(service, session.clone())?;
    library.start(mode != Some("--resume"));
    let connection = tokio::spawn(connection);
    loop {
        tokio::select! {
            line = commands.recv() => {
                let Some(line) = line else { break };
                if line.len() > 4096 {
                    emit(json!({"event": "error", "message": "The player command is too long."}));
                    continue;
                }
                match serde_json::from_str::<Command>(&line) {
                    Ok(Command::AuthorizeLibrary) => library.start(true),
                    Ok(Command::Catalog { request }) => library.catalog(request),
                    Ok(Command::QueueAdd { uri }) => library.mutate("queueAdd", Some(uri), false, None),
                    Ok(Command::SetSaved { uri, saved }) => library.mutate("setSaved", Some(uri), saved, None),
                    Ok(Command::CreatePlaylist { name }) => library.mutate("createPlaylist", None, false, Some(name)),
                    Ok(command) => match execute(&spirc, command) {
                        Ok(true) => {},
                        Ok(false) => break,
                        Err(_) => emit(json!({"event": "error", "message": "Spotify could not perform this playback command."})),
                    },
                    Err(_) => emit(json!({"event": "error", "message": "The player command is invalid."})),
                }
            }
            event = events.recv() => {
                let Some(event) = event else { break };
                match event {
                    PlayerEvent::TrackChanged { audio_item } => {
                        if let Ok(uri) = audio_item.track_id.to_uri() { library.track_changed(uri); }
                        let (artist, album) = match &audio_item.unique_fields {
                            UniqueFields::Track { artists, album, .. } => (
                                artists.iter().map(|artist| artist.name.as_str()).collect::<Vec<_>>().join(", "),
                                album.clone(),
                            ),
                            UniqueFields::Episode { show_name, .. } => (show_name.clone(), String::new()),
                            UniqueFields::Local { artists, album, .. } => (
                                artists.clone().unwrap_or_default(), album.clone().unwrap_or_default(),
                            ),
                        };
                        emit(json!({
                            "event": "track", "title": audio_item.name,
                            "uri": audio_item.track_id.to_uri().ok(),
                            "artist": artist, "album": album,
                            "artwork": audio_item.covers.first().map(|cover| &cover.url),
                            "duration": f64::from(audio_item.duration_ms) / 1000.0,
                        }));
                    },
                    PlayerEvent::Playing { position_ms, .. } => emit(json!({"event": "state", "playing": true, "elapsed": f64::from(position_ms) / 1000.0})),
                    PlayerEvent::Paused { position_ms, .. } => emit(json!({"event": "state", "playing": false, "elapsed": f64::from(position_ms) / 1000.0})),
                    PlayerEvent::PositionChanged { position_ms, .. } | PlayerEvent::Seeked { position_ms, .. } | PlayerEvent::PositionCorrection { position_ms, .. } => emit(json!({"event": "position", "elapsed": f64::from(position_ms) / 1000.0})),
                    PlayerEvent::Stopped { .. } => emit(json!({"event": "state", "playing": false, "elapsed": 0})),
                    PlayerEvent::Unavailable { .. } => emit(json!({"event": "error", "message": "Spotify could not play this item. Check Premium and its availability in your region."})),
                    PlayerEvent::VolumeChanged { volume } => emit(json!({"event": "volume", "value": f64::from(volume) / f64::from(u16::MAX)})),
                    PlayerEvent::ShuffleChanged { shuffle } => emit(json!({"event":"state","shuffle":shuffle})),
                    PlayerEvent::RepeatChanged { context, track } => emit(json!({"event":"state","repeat":if track { "track" } else if context { "context" } else { "off" }})),
                    _ => {},
                }
            }
            _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => {
                if connection.is_finished() { break; }
            }
        }
    }
    let _ = spirc.shutdown();
    connection.abort();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_account_modes_without_using_the_executable_as_identity() {
        let args =
            Arguments::try_parse_from(["untrusted", "test.service", "Music", "--resume"]).unwrap();
        assert_eq!(args.service, "test.service");
        assert_eq!(args.name, "Music");
        assert!(args.resume);
        assert!(!args.forget);
        assert!(Arguments::try_parse_from(["player", "test.service"]).is_err());
        assert!(
            Arguments::try_parse_from(["player", "test.service", "Music", "--unknown"]).is_err()
        );
        assert!(
            Arguments::try_parse_from(["player", "test.service", "Music", "--resume", "--forget"])
                .is_err()
        );
    }

    #[test]
    fn native_bridge_owns_commands_callbacks_and_cancellation() {
        use std::sync::{Arc, atomic::AtomicUsize};
        static CALLBACKS: AtomicUsize = AtomicUsize::new(0);
        unsafe extern "C" fn callback(data: *const u8, length: usize, _: *mut c_void) {
            let value: Value =
                serde_json::from_slice(unsafe { std::slice::from_raw_parts(data, length) })
                    .unwrap();
            assert_eq!(value["event"], "mock");
            CALLBACKS.fetch_add(1, Ordering::Relaxed);
        }
        let stopped = Arc::new(AtomicBool::new(false));
        let observed = stopped.clone();
        let handle = launch("test.service".into(), "Mock music".into(), None,
            EventSink { callback, context: 0 }, move |_, _, _, mut commands, mut cancelled| {
                let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
                runtime.block_on(async {
                    loop {
                        tokio::select! {
                            Some(command) = commands.recv() => { assert!(serde_json::from_str::<Command>(&command).is_ok()); emit(json!({"event":"mock"})); }
                            _ = &mut cancelled => break,
                        }
                    }
                });
                observed.store(true, Ordering::Release);
            }).unwrap();
        assert!(
            launch(
                "second".into(),
                "Mock".into(),
                None,
                EventSink {
                    callback,
                    context: 0
                },
                |_, _, _, _, _| {}
            )
            .is_none()
        );
        let pointer = Box::into_raw(handle).cast();
        let command = br#"{"action":"volume","value":0.3}"#;
        assert!(unsafe { edith_music_player_send(pointer, command.as_ptr(), command.len()) });
        let invalid = br#"{"action":"execute"}"#;
        assert!(!unsafe { edith_music_player_send(pointer, invalid.as_ptr(), invalid.len()) });
        assert!(!unsafe { edith_music_player_send(pointer, command.as_ptr(), 4097) });
        for _ in 0..100 {
            if CALLBACKS.load(Ordering::Relaxed) == 1 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert_eq!(CALLBACKS.load(Ordering::Relaxed), 1);
        unsafe { edith_music_player_stop(pointer) };
        assert!(stopped.load(Ordering::Acquire));
        assert!(!ACTIVE.load(Ordering::Acquire));
        assert!(EVENT_SINK.lock().unwrap().is_none());
        let restart = launch(
            "test.service".into(),
            "Mock music".into(),
            None,
            EventSink {
                callback,
                context: 0,
            },
            |_, _, _, _, cancelled| {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                    .unwrap();
                runtime.block_on(async {
                    let _ = cancelled.await;
                });
            },
        )
        .unwrap();
        drop(restart);
        assert!(!ACTIVE.load(Ordering::Acquire));
        assert!(
            unsafe {
                edith_music_player_start(
                    std::ptr::null(),
                    std::ptr::null(),
                    0,
                    Some(callback),
                    std::ptr::null_mut(),
                )
            }
            .is_null()
        );
        assert!(!unsafe {
            edith_music_player_send(std::ptr::null_mut(), command.as_ptr(), command.len())
        });
    }

    #[test]
    fn accepts_supported_spotify_uris() {
        for kind in ["track", "album", "playlist", "episode"] {
            assert!(valid_uri(&format!("spotify:{kind}:0123456789abcdefghijkl")));
        }
    }

    #[test]
    fn rejects_invalid_and_unrelated_uris() {
        for uri in [
            "spotify:track:abc",
            "spotify:user:0123456789abcdefghijkl",
            "spotify:track:0123456789abcdefghijk!",
            "https://example.com",
        ] {
            assert!(!valid_uri(uri));
        }
    }

    #[test]
    fn parses_commands_without_shell_interpolation() {
        assert!(matches!(
            serde_json::from_str::<Command>(r#"{"action":"seek","milliseconds":1234}"#).unwrap(),
            Command::Seek { milliseconds: 1234 }
        ));
        assert!(serde_json::from_str::<Command>(r#"{"action":"seek","milliseconds":-1}"#).is_err());
        assert!(
            serde_json::from_str::<Command>(r#"{"action":"execute","script":"something"}"#)
                .is_err()
        );
    }
}
mod catalog;
mod session_catalog;
