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
use std::io::{self, Write};
use tokio::io::{AsyncBufReadExt, BufReader};

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

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
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
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    loop {
        tokio::select! {
            line = lines.next_line() => {
                let Some(line) = line? else { break };
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

#[tokio::main]
async fn main() {
    let args = Arguments::parse();
    let mode = if args.forget {
        Some("--forget")
    } else if args.resume {
        Some("--resume")
    } else {
        None
    };
    if run(&args.service, &args.name, mode).await.is_err() {
        emit(
            json!({"event": "error", "message": "Spotify could not connect. Check your internet connection and Premium account, or disconnect and sign in again."}),
        );
        std::process::exit(1);
    }
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
