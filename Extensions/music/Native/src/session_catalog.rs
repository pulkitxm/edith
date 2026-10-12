use super::catalog::{Request, item};
use librespot::{
    core::{Session, SpotifyUri},
    metadata::{Episode, Metadata, Playlist, Track},
    protocol::playlist4_external::SelectedListContent,
};
use protobuf::Message;
use reqwest::Method;
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};
use tokio::{sync::Semaphore, task::JoinSet};

pub async fn playlist(
    session: &Session,
    request: &Request,
    slots: Arc<Semaphore>,
) -> Result<Value, String> {
    let id = request
        .id
        .as_deref()
        .ok_or("A Spotify playlist is required.")?;
    let uri = SpotifyUri::from_uri(&format!("spotify:playlist:{id}"))
        .map_err(|_| "This playlist ID is invalid.")?;
    let endpoint = format!(
        "/playlist/v2/playlist/{id}?decorate=revision,attributes,length,owner&from={}&length=20",
        request.offset
    );
    let response = tokio::time::timeout(
        Duration::from_secs(30),
        session
            .spclient()
            .request(&Method::GET, &endpoint, None, None),
    )
    .await
    .map_err(|_| "Spotify playlist loading timed out.")?
    .map_err(|_| "This playlist is unavailable for the current account.")?;
    if response.len() > 2_000_000 {
        return Err("Spotify returned an oversized playlist.".into());
    }
    let message = SelectedListContent::parse_from_bytes(&response)
        .map_err(|_| "Spotify returned an invalid playlist.")?;
    let list =
        Playlist::parse(&message, &uri).map_err(|_| "Spotify returned an invalid playlist.")?;
    if list.contents.position.max(0) as u32 > request.offset {
        return Err("Spotify returned an invalid playlist window.".into());
    }
    let start = request
        .offset
        .saturating_sub(list.contents.position.max(0) as u32) as usize;
    let rows: Vec<_> = list
        .contents
        .items
        .iter()
        .skip(start)
        .take(20)
        .map(|row| row.id.clone())
        .collect();
    let total = list.length.max(0) as u32;
    let next = next_offset(request.offset, rows.len(), total)?;
    let mut tasks = JoinSet::new();
    for (index, uri) in rows.into_iter().enumerate() {
        let session = session.clone();
        let slots = Arc::clone(&slots);
        let offset = request.offset;
        tasks.spawn(async move {
            let _permit = slots
                .acquire()
                .await
                .map_err(|_| "The playlist reader is closed.")?;
            let value = tokio::time::timeout(Duration::from_secs(10), track(&session, &uri))
                .await
                .map_err(|_| "A playlist item timed out. Retry shortly.")??;
            Ok::<_, String>(value.map(|mut value| {
                value["position"] = json!(offset.saturating_add(index as u32));
                (index, value)
            }))
        });
    }
    let mut items = Vec::new();
    while let Some(result) = tasks.join_next().await {
        if let Some(value) = result.map_err(|_| "A playlist item could not load.")?? {
            items.push(value);
        }
    }
    items.sort_by_key(|(index, _)| *index);
    let items: Vec<_> = items.into_iter().map(|(_, value)| value).collect();
    let owner = match &list.id {
        SpotifyUri::Playlist {
            user: Some(owner), ..
        } => owner.as_str(),
        _ => "",
    };
    let image = list
        .attributes
        .picture_sizes
        .first()
        .map(|picture| picture.url.clone())
        .filter(|url| url.starts_with("https://"))
        .or_else(|| {
            (!list.attributes.picture.is_empty()).then(|| {
                format!(
                    "https://i.scdn.co/image/{}",
                    list.attributes
                        .picture
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<String>()
                )
            })
        });
    let header = json!({"id":id,"type":"playlist","name":list.attributes.name,"description":list.attributes.description,"images":[{"url":image}],"owner":{"display_name":owner}});
    Ok(json!({"items":items,"total":total,"nextOffset":next,"current":item(&header,"playlist")}))
}

fn next_offset(offset: u32, count: usize, total: u32) -> Result<Option<u32>, String> {
    let end = offset.saturating_add(count as u32);
    if count < 20 && end < total {
        return Err("Spotify returned an incomplete playlist page. Retry shortly.".into());
    }
    Ok((end < total).then_some(end))
}

async fn track(session: &Session, uri: &SpotifyUri) -> Result<Option<Value>, String> {
    let text = uri.to_uri().map_err(|_| "This playlist item is invalid.")?;
    let id = text
        .rsplit(':')
        .next()
        .ok_or("This playlist item is invalid.")?;
    let value = match uri {
        SpotifyUri::Track { .. } => {
            let Some(track) = metadata::<Track>(session, uri).await? else {
                return Ok(None);
            };
            let images: Vec<_> = track
                .album
                .covers
                .iter()
                .filter_map(|cover| {
                    cover
                        .id
                        .to_base16()
                        .ok()
                        .map(|id| json!({"url":format!("https://i.scdn.co/image/{id}")}))
                })
                .collect();
            let artists: Vec<_> = track
                .artists
                .iter()
                .map(|artist| json!({"name":artist.name}))
                .collect();
            json!({"id":id,"type":"track","name":track.name,"duration_ms":track.duration,"artists":artists,"album":{"name":track.album.name,"images":images}})
        }
        SpotifyUri::Episode { .. } => {
            let Some(episode) = metadata::<Episode>(session, uri).await? else {
                return Ok(None);
            };
            let images: Vec<_> = episode
                .covers
                .iter()
                .filter_map(|cover| {
                    cover
                        .id
                        .to_base16()
                        .ok()
                        .map(|id| json!({"url":format!("https://i.scdn.co/image/{id}")}))
                })
                .collect();
            json!({"id":id,"type":"episode","name":episode.name,"duration_ms":episode.duration,"publisher":episode.show_name,"images":images})
        }
        _ => return Ok(None),
    };
    Ok(item(&value, "track"))
}

async fn metadata<T: Metadata>(session: &Session, uri: &SpotifyUri) -> Result<Option<T>, String> {
    match T::get(session, uri).await {
        Ok(value) => Ok(Some(value)),
        Err(error)
            if matches!(
                error.kind,
                librespot::core::error::ErrorKind::NotFound
                    | librespot::core::error::ErrorKind::PermissionDenied
            ) =>
        {
            Ok(None)
        }
        Err(_) => Err("Spotify could not load a playlist item. Retry shortly.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn playlist_pagination_uses_original_positions_and_rejects_incomplete_windows() {
        assert_eq!(next_offset(40, 20, 61).unwrap(), Some(60));
        assert_eq!(next_offset(60, 1, 61).unwrap(), None);
        assert_eq!(next_offset(100, 0, 100).unwrap(), None);
        assert!(next_offset(40, 10, 100).is_err());
    }
    #[test]
    fn playlist_header_matches_the_catalog_schema() {
        let value = json!({"id":"0123456789abcdefghijkl","type":"playlist","name":"Sample mix","description":"Sample description","owner":{"display_name":"Sample owner"},"images":[{"url":"https://mosaic.scdn.co/300/sample"}]});
        let header = item(&value, "playlist").unwrap();
        assert_eq!(header["uri"], "spotify:playlist:0123456789abcdefghijkl");
        assert_eq!(header["title"], "Sample mix");
        assert_eq!(header["owner"], "Sample owner");
        assert_eq!(header["artwork"], "https://mosaic.scdn.co/300/sample");
    }
}
