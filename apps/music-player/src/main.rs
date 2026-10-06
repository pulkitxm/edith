use librespot::{
    connect::{ConnectConfig, LoadRequest, LoadRequestOptions, Spirc},
    core::{authentication::Credentials, config::SessionConfig, session::Session},
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

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
enum Command {
    Play { uri: String },
    Toggle,
    Pause,
    Next,
    Previous,
    Seek { milliseconds: u32 },
    Volume { value: f64 },
    Disconnect,
}

fn emit(value: Value) {
    let mut out = io::stdout().lock();
    let _ = writeln!(out, "{value}");
    let _ = out.flush();
}

fn valid_uri(uri: &str) -> bool {
    let pieces: Vec<_> = uri.split(':').collect();
    pieces.len() == 3
        && pieces[0] == "spotify"
        && ["track", "album", "playlist", "episode"].contains(&pieces[1])
        && pieces[2].len() == 22
        && pieces[2].bytes().all(|b| b.is_ascii_alphanumeric())
}

fn execute(spirc: &Spirc, command: Command) -> Result<bool, librespot::core::Error> {
    match command {
        Command::Play { uri } => {
            if !valid_uri(&uri) {
                return Err(librespot::core::Error::invalid_argument(
                    "invalid Spotify link",
                ));
            }
            spirc.activate()?;
            spirc.load(LoadRequest::from_context_uri(
                uri,
                LoadRequestOptions::default(),
            ))?;
            spirc.play()?;
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
        Command::Disconnect => {
            spirc.shutdown()?;
            return Ok(false);
        }
    }
    Ok(true)
}

async fn run(service: &str, name: &str, forget: bool) -> Result<(), Box<dyn std::error::Error>> {
    let entry = keyring::Entry::new(service, "spotify")?;
    if forget {
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
        PlayerConfig::default(),
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
                    PlayerEvent::TrackChanged { audio_item } => emit(json!({
                        "event": "track", "title": audio_item.name,
                        "duration": f64::from(audio_item.duration_ms) / 1000.0,
                    })),
                    PlayerEvent::Playing { position_ms, .. } => emit(json!({"event": "state", "playing": true, "elapsed": f64::from(position_ms) / 1000.0})),
                    PlayerEvent::Paused { position_ms, .. } => emit(json!({"event": "state", "playing": false, "elapsed": f64::from(position_ms) / 1000.0})),
                    PlayerEvent::Stopped { .. } => emit(json!({"event": "state", "playing": false, "elapsed": 0})),
                    PlayerEvent::Unavailable { .. } => emit(json!({"event": "error", "message": "Spotify could not play this item. Check Premium and its availability in your region."})),
                    PlayerEvent::VolumeChanged { volume } => emit(json!({"event": "volume", "value": f64::from(volume) / f64::from(u16::MAX)})),
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
    let args: Vec<_> = std::env::args().collect();
    if args.len() < 3 || args.len() > 4 {
        std::process::exit(2);
    }
    if run(
        &args[1],
        &args[2],
        args.get(3).is_some_and(|arg| arg == "--forget"),
    )
    .await
    .is_err()
    {
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
