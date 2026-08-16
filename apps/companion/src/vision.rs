use std::env;
use std::fmt::{Display, Formatter};

use base64::Engine;
use reqwest::Client;
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Debug)]
pub struct VisionError(String);

impl Display for VisionError {
    fn fmt(&self, formatter: &mut Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.0)
    }
}

impl std::error::Error for VisionError {}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Exif {
    pub taken_at: Option<String>,
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    pub camera: Option<String>,
    pub album: Option<String>,
}

impl Exif {
    pub fn prompt_line(&self) -> String {
        let mut parts = Vec::new();
        if let Some(taken_at) = &self.taken_at {
            parts.push(format!("taken {taken_at}"));
        }
        if let (Some(latitude), Some(longitude)) = (self.latitude, self.longitude) {
            parts.push(format!("at {latitude:.4}, {longitude:.4}"));
        }
        if let Some(camera) = &self.camera {
            parts.push(format!("on a {camera}"));
        }
        if let Some(album) = &self.album {
            parts.push(format!("filed under {album}"));
        }
        if parts.is_empty() {
            "no capture metadata was recorded".to_owned()
        } else {
            parts.join(", ")
        }
    }
}

pub fn exif_from_json(value: &Value, album: Option<String>) -> Exif {
    let read = |keys: [&str; 2]| {
        keys.iter()
            .find_map(|key| value.get(*key).and_then(Value::as_str))
            .map(str::to_owned)
    };
    Exif {
        taken_at: read(["DateTimeOriginal", "dateTaken"]),
        latitude: value
            .get("GPSLatitude")
            .or_else(|| value.get("latitude"))
            .and_then(Value::as_f64),
        longitude: value
            .get("GPSLongitude")
            .or_else(|| value.get("longitude"))
            .and_then(Value::as_f64),
        camera: read(["Model", "camera"]),
        album,
    }
}

#[derive(Clone)]
pub struct VisionClient {
    client: Client,
    base_url: String,
    model: String,
}

pub const CAPTION_PROMPT: &str = "Describe this image the way someone would describe it to \
find it again years later. Say what is in it, what is happening, and read out any text you can \
see. Use the capture details given to name the place or occasion when they support it, and do \
not guess at one when they do not. Do not describe anyone's mood or feelings from their face. \
Four sentences at most, plain prose.";

impl VisionClient {
    pub fn from_env() -> Self {
        Self {
            client: Client::new(),
            base_url: env::var("VLM_URL")
                .unwrap_or_else(|_| "http://127.0.0.1:11434".to_owned())
                .trim_end_matches('/')
                .to_owned(),
            model: env::var("VLM_MODEL").unwrap_or_else(|_| "qwen3-vl:8b".to_owned()),
        }
    }

    pub fn model(&self) -> &str {
        &self.model
    }

    pub fn describe(&self) -> String {
        format!("{} at {}", self.model, self.base_url)
    }

    pub async fn caption(&self, bytes: &[u8], exif: &Exif) -> Result<String, VisionError> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(bytes);
        let prompt = format!("{CAPTION_PROMPT}\n\nCapture details: {}", exif.prompt_line());
        let response = self
            .client
            .post(format!("{}/api/generate", self.base_url))
            .json(&json!({
                "model": self.model,
                "prompt": prompt,
                "images": [encoded],
                "stream": false,
            }))
            .send()
            .await
            .map_err(|error| VisionError(format!("Vision request failed: {error}")))?;
        let status = response.status();
        let text = response
            .text()
            .await
            .map_err(|error| VisionError(format!("Vision body unreadable: {error}")))?;
        if !status.is_success() {
            return Err(VisionError(format!("Vision returned {status}: {text}")));
        }
        let value = serde_json::from_str::<Value>(&text)
            .map_err(|error| VisionError(format!("Vision response was not JSON: {error}")))?;
        let caption = value
            .get("response")
            .and_then(Value::as_str)
            .or_else(|| value.pointer("/choices/0/message/content").and_then(Value::as_str))
            .map(str::trim)
            .filter(|caption| !caption.is_empty())
            .ok_or_else(|| VisionError(format!("Vision response had no caption: {text}")))?;
        Ok(caption.to_owned())
    }

    pub async fn probe(&self) -> Result<String, VisionError> {
        let response = self
            .client
            .get(format!("{}/api/tags", self.base_url))
            .send()
            .await
            .map_err(|error| VisionError(format!("Vision probe failed: {error}")))?;
        if !response.status().is_success() {
            return Err(VisionError(format!(
                "Vision endpoint returned {}",
                response.status()
            )));
        }
        let listing = response
            .json::<serde_json::Value>()
            .await
            .map_err(|error| VisionError(format!("Vision probe unreadable: {error}")))?;
        let present = listing["models"]
            .as_array()
            .map(|models| {
                models.iter().any(|entry| {
                    entry["name"]
                        .as_str()
                        .is_some_and(|name| name == self.model || name.starts_with(&self.model))
                })
            })
            .unwrap_or(false);
        if present {
            Ok(self.describe())
        } else {
            Err(VisionError(format!(
                "model {} is not pulled on the vision endpoint",
                self.model
            )))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{Exif, exif_from_json};
    use serde_json::json;

    #[test]
    fn capture_details_read_as_a_sentence() {
        let exif = exif_from_json(
            &json!({"DateTimeOriginal": "2024-03-02T18:04:00Z", "GPSLatitude": 28.61, "GPSLongitude": 77.20, "Model": "iPhone 15"}),
            Some("Goa".to_owned()),
        );
        let line = exif.prompt_line();
        assert!(line.contains("2024-03-02"));
        assert!(line.contains("28.6100"));
        assert!(line.contains("iPhone 15"));
        assert!(line.contains("Goa"));
    }

    #[test]
    fn a_photo_with_nothing_recorded_says_so() {
        assert_eq!(
            Exif::default().prompt_line(),
            "no capture metadata was recorded"
        );
    }
}
