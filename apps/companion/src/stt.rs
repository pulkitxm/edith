use std::env;
use std::error::Error;
use std::fmt::{Display, Formatter};

use reqwest::Client;
use reqwest::multipart::{Form, Part};
use serde::Deserialize;

#[derive(Debug)]
pub struct SttError(String);

impl Display for SttError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl Error for SttError {}

#[derive(Clone)]
pub struct SttClient {
    client: Client,
    base_url: String,
}

#[derive(Debug, Deserialize)]
pub struct TranscriptSegment {
    #[serde(default)]
    pub start: f32,
    #[serde(default)]
    pub end: f32,
    pub text: String,
}

#[derive(Debug, Deserialize)]
pub struct Transcript {
    pub text: String,
    pub language: Option<String>,
    pub duration: Option<f32>,
    #[serde(default)]
    pub segments: Vec<TranscriptSegment>,
}

impl SttClient {
    pub fn from_env() -> Self {
        let base_url = env::var("STT_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:8081".to_owned())
            .trim_end_matches('/')
            .to_owned();
        Self {
            client: Client::new(),
            base_url,
        }
    }

    pub fn at(base_url: &str) -> Self {
        Self {
            client: Client::new(),
            base_url: base_url.trim_end_matches('/').to_owned(),
        }
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub async fn transcribe(&self, name: &str, bytes: Vec<u8>) -> Result<Transcript, SttError> {
        let part = Part::bytes(bytes)
            .file_name(name.to_owned())
            .mime_str("application/octet-stream")
            .map_err(|error| SttError(error.to_string()))?;
        let form = Form::new()
            .part("file", part)
            .text("response_format", "verbose_json")
            .text("temperature", "0.0");
        let response = self
            .client
            .post(format!("{}/inference", self.base_url))
            .multipart(form)
            .send()
            .await
            .map_err(|error| SttError(format!("Transcription request failed: {error}")))?;
        let status = response.status();
        let body = response
            .text()
            .await
            .map_err(|error| SttError(format!("Transcription response unreadable: {error}")))?;
        if !status.is_success() {
            return Err(SttError(format!(
                "Transcription endpoint returned {status}: {body}"
            )));
        }
        let transcript = serde_json::from_str::<Transcript>(&body)
            .map_err(|error| SttError(format!("Invalid transcription response: {error}")))?;
        if transcript.text.trim().is_empty() {
            return Err(SttError("Transcription produced no text".to_owned()));
        }
        Ok(transcript)
    }

    pub async fn probe(&self) -> Result<String, SttError> {
        let response = self
            .client
            .get(format!("{}/", self.base_url))
            .send()
            .await
            .map_err(|error| SttError(format!("Transcription probe failed: {error}")))?;
        let status = response.status();
        if status.is_success() {
            Ok("reachable".to_owned())
        } else {
            Err(SttError(format!(
                "Transcription endpoint returned {status}"
            )))
        }
    }
}
