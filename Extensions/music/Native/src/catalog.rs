use oauth2::{
    AuthUrl, AuthorizationCode, ClientId, CsrfToken, EndpointNotSet, EndpointSet,
    PkceCodeChallenge, RedirectUrl, RefreshToken, Scope, TokenResponse, TokenUrl,
    basic::{BasicClient, BasicTokenType},
};
use reqwest::{Client, Method, Url};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::TcpListener,
    sync::{Mutex, Semaphore},
};

const CLIENT_ID: &str = "d420a117a32841c2b3474932e49fb54b";
const REDIRECT: &str = "http://127.0.0.1:8989/login";
const SCOPES: &[&str] = &[
    "playlist-read-private",
    "playlist-read-collaborative",
    "user-library-read",
    "user-library-modify",
    "user-follow-read",
    "user-follow-modify",
    "user-read-private",
    "user-read-recently-played",
    "user-top-read",
    "user-read-playback-state",
    "user-modify-playback-state",
    "playlist-modify-private",
    "playlist-modify-public",
];
type OAuth = BasicClient<EndpointSet, EndpointNotSet, EndpointNotSet, EndpointNotSet, EndpointSet>;
type Token = oauth2::StandardTokenResponse<oauth2::EmptyExtraTokenFields, BasicTokenType>;
type Result<T> = std::result::Result<T, String>;

fn oauth() -> OAuth {
    BasicClient::new(ClientId::new(CLIENT_ID.into()))
        .set_auth_uri(AuthUrl::new("https://accounts.spotify.com/authorize".into()).unwrap())
        .set_token_uri(TokenUrl::new("https://accounts.spotify.com/api/token".into()).unwrap())
        .set_redirect_uri(RedirectUrl::new(REDIRECT.into()).unwrap())
}

fn open_browser(url: &str) -> Result<()> {
    open::that(url).map_err(|_| "The Spotify sign-in browser could not open.".into())
}

pub async fn streaming_authorization(client_id: &str) -> Result<String> {
    let client = BasicClient::new(ClientId::new(client_id.into()))
        .set_auth_uri(AuthUrl::new("https://accounts.spotify.com/authorize".into()).unwrap())
        .set_token_uri(TokenUrl::new("https://accounts.spotify.com/api/token".into()).unwrap())
        .set_redirect_uri(RedirectUrl::new("http://127.0.0.1:8898/login".into()).unwrap());
    let http = Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|_| "The Spotify authorization client could not start.")?;
    let token = tokio::time::timeout(
        Duration::from_secs(600),
        authorize_with(
            client,
            &http,
            "127.0.0.1:8898",
            &["streaming"],
            open_browser,
        ),
    )
    .await
    .map_err(|_| "Spotify authorization timed out.")??;
    Ok(token.access_token().secret().clone())
}

async fn authorize_with(
    client: OAuth,
    http: &Client,
    address: &str,
    scopes: &[&str],
    open_browser: impl FnOnce(&str) -> Result<()>,
) -> Result<Token> {
    let listener = TcpListener::bind(address).await.map_err(
        |_| "Another Spotify sign-in is using the library callback. Close it and try again.",
    )?;
    let (challenge, verifier) = PkceCodeChallenge::new_random_sha256();
    let (url, state) = client
        .authorize_url(CsrfToken::new_random)
        .add_scopes(scopes.iter().map(|s| Scope::new((*s).into())))
        .set_pkce_challenge(challenge)
        .url();
    open_browser(url.as_str())?;
    loop {
        let (mut stream, _) = listener
            .accept()
            .await
            .map_err(|_| "The Spotify callback could not be accepted.")?;
        let mut line = String::new();
        let read = tokio::time::timeout(
            Duration::from_secs(5),
            BufReader::new((&mut stream).take(4096)).read_line(&mut line),
        )
        .await;
        let code = if matches!(read, Ok(Ok(_))) {
            callback(&line, state.secret())
        } else {
            None
        };
        let body = match &code {
            Some(Ok(_)) => "Connected. Return to Edith.",
            Some(Err(_)) => "Sign-in declined. Return to Edith to retry.",
            None => "This sign-in callback is invalid.",
        };
        let response = format!(
            "HTTP/1.1 {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            if code.is_some() {
                "200 OK"
            } else {
                "400 Bad Request"
            },
            body.len(),
            body
        );
        let _ = tokio::time::timeout(
            Duration::from_secs(5),
            stream.write_all(response.as_bytes()),
        )
        .await;
        if let Some(code) = code {
            return client
                .exchange_code(AuthorizationCode::new(code?))
                .set_pkce_verifier(verifier)
                .request_async(http)
                .await
                .map_err(|_| {
                    "Spotify library authorization was declined. Connect again to retry.".into()
                });
        }
    }
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

#[derive(Clone, Serialize, Deserialize)]
struct Grant {
    access_token: String,
    refresh_token: String,
    expires_at: u64,
    account: String,
}

impl Grant {
    fn renewed(token: Token, previous: Option<&Self>, account: String) -> Result<Self> {
        let refresh_token = token
            .refresh_token()
            .map(|t| t.secret().clone())
            .or_else(|| previous.map(|t| t.refresh_token.clone()))
            .filter(|t| !t.is_empty())
            .ok_or("Spotify did not return a reusable library grant.")?;
        Ok(Self {
            access_token: token.access_token().secret().clone(),
            refresh_token,
            expires_at: now()
                + token
                    .expires_in()
                    .unwrap_or(Duration::from_secs(3600))
                    .as_secs(),
            account,
        })
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub request_id: String,
    pub kind: String,
    pub id: Option<String>,
    pub query: Option<String>,
    #[serde(default)]
    pub offset: u32,
    pub cursor: Option<String>,
}

pub struct Library {
    client: Client,
    grant: Mutex<Option<Grant>>,
    authorizing: std::sync::atomic::AtomicBool,
    ready: std::sync::atomic::AtomicBool,
    current: std::sync::Mutex<Option<String>>,
    queue_writes: Mutex<()>,
    saved_state: Mutex<()>,
    slots: Arc<Semaphore>,
    service: String,
    account: String,
    device: String,
    session: librespot::core::Session,
}

impl Library {
    pub fn new(service: &str, session: librespot::core::Session) -> Result<Arc<Self>> {
        let account = session.username();
        let device = session.device_id().to_owned();
        let client = Client::builder()
            .timeout(Duration::from_secs(30))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| "The library network client could not start.")?;
        let grant = Self::entry(service)?
            .get_password()
            .ok()
            .and_then(|v| serde_json::from_str::<Grant>(&v).ok())
            .filter(|t| t.account == account);
        Ok(Arc::new(Self {
            client,
            grant: Mutex::new(grant),
            authorizing: false.into(),
            ready: false.into(),
            current: std::sync::Mutex::new(None),
            queue_writes: Mutex::new(()),
            saved_state: Mutex::new(()),
            slots: Arc::new(Semaphore::new(4)),
            service: service.into(),
            account,
            device,
            session,
        }))
    }

    fn entry(service: &str) -> Result<keyring::Entry> {
        keyring::Entry::new(service, "spotify-library")
            .map_err(|_| "The library Keychain entry is unavailable.".into())
    }

    pub fn forget(service: &str) -> Result<()> {
        match Self::entry(service)?.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
            Err(_) => Err("The library account could not be removed from Keychain.".into()),
        }
    }

    fn state(ready: bool, authorizing: bool, error: Option<String>) {
        super::emit(
            json!({"event":"libraryState", "ready":ready,"authorizing":authorizing,"error":error}),
        );
    }

    fn persist(&self, grant: &Grant) -> Result<()> {
        Self::entry(&self.service)?
            .set_password(
                &serde_json::to_string(grant)
                    .map_err(|_| "The library grant could not be saved.")?,
            )
            .map_err(|_| "The library grant could not be saved in Keychain.".into())
    }

    pub fn start(self: &Arc<Self>, authorize: bool) {
        use std::sync::atomic::Ordering;
        if self.authorizing.swap(true, Ordering::SeqCst) {
            return;
        }
        self.ready.store(false, Ordering::SeqCst);
        let library = Arc::clone(self);
        tokio::spawn(async move {
            Self::state(false, true, None);
            let result = library.initialize(authorize).await;
            library.authorizing.store(false, Ordering::SeqCst);
            match result {
                Ok(ready) => {
                    library.ready.store(ready, Ordering::SeqCst);
                    Self::state(ready, false, None);
                    let current = library
                        .current
                        .lock()
                        .unwrap_or_else(|p| p.into_inner())
                        .clone();
                    if ready && let Some(uri) = current {
                        library.saved_status(&uri).await;
                    }
                }
                Err(error) => Self::state(false, false, Some(error)),
            }
        });
    }

    async fn initialize(&self, authorize: bool) -> Result<bool> {
        if authorize {
            let token = tokio::time::timeout(Duration::from_secs(600), self.authorize())
                .await
                .map_err(|_| "Library sign-in timed out. Connect the library again.")??;
            let grant = Grant::renewed(token, None, self.account.clone())?;
            let response = self
                .client
                .get("https://api.spotify.com/v1/me")
                .bearer_auth(&grant.access_token)
                .send()
                .await
                .map_err(|_| "Spotify could not verify your library account.")?;
            verify_account(&decode(response, &Method::GET).await?, &self.account)?;
            self.persist(&grant)?;
            *self.grant.lock().await = Some(grant);
        } else {
            if self.grant.lock().await.is_none() {
                return Ok(false);
            }
            let account = self.request(Method::GET, "/me", vec![], None).await?;
            verify_account(&account, &self.account)?;
        }
        Ok(true)
    }

    async fn authorize(&self) -> Result<Token> {
        authorize_with(
            oauth(),
            &self.client,
            "127.0.0.1:8989",
            SCOPES,
            open_browser,
        )
        .await
    }

    async fn token(&self, force: bool) -> Result<String> {
        let mut stored = self.grant.lock().await;
        let grant = stored
            .as_ref()
            .ok_or("Connect your Spotify library to browse your music.")?;
        if force || grant.expires_at <= now().saturating_add(60) {
            let refreshed = oauth()
                .exchange_refresh_token(&RefreshToken::new(grant.refresh_token.clone()))
                .request_async(&self.client)
                .await
                .map_err(|_| "Your Spotify library sign-in expired. Connect it again.")?;
            let updated = Grant::renewed(refreshed, Some(grant), self.account.clone())?;
            self.persist(&updated)?;
            *stored = Some(updated);
        }
        Ok(stored.as_ref().unwrap().access_token.clone())
    }

    async fn request(
        &self,
        method: Method,
        path: &str,
        query: Vec<(&str, String)>,
        body: Option<Value>,
    ) -> Result<Value> {
        let _permit = self
            .slots
            .acquire()
            .await
            .map_err(|_| "The Spotify library is closed.")?;
        let mut refresh = false;
        for attempt in 0..3 {
            let token = self.token(refresh).await?;
            let mut request = self
                .client
                .request(method.clone(), format!("https://api.spotify.com/v1{path}"))
                .bearer_auth(token)
                .query(&query);
            if let Some(body) = &body {
                request = request.json(body);
            }
            let response = request
                .send()
                .await
                .map_err(|_| "Spotify could not be reached. Check your connection and retry.")?;
            let status = response.status();
            if status.as_u16() == 401 && attempt == 0 {
                refresh = true;
                continue;
            }
            if status.as_u16() == 429 && attempt < 2 {
                let seconds = response
                    .headers()
                    .get("retry-after")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|v| v.parse::<u64>().ok())
                    .unwrap_or(2);
                if seconds > 30 {
                    return Err("Spotify is rate limiting the library. Try again shortly.".into());
                }
                tokio::time::sleep(Duration::from_secs(seconds)).await;
                continue;
            }
            return decode(response, &method).await;
        }
        Err("Spotify could not complete this library request.".into())
    }

    pub fn catalog(self: &Arc<Self>, request: Request) {
        let library = Arc::clone(self);
        tokio::spawn(async move {
            let mut event = match library.read(&request).await {
                Ok(event) => event,
                Err(error) => json!({"items":[], "error":error}),
            };
            event["event"] = json!("catalog");
            event["requestId"] = json!(text(&request.request_id, 100));
            super::emit(event);
        });
    }

    async fn read(&self, request: &Request) -> Result<Value> {
        if !self.ready.load(std::sync::atomic::Ordering::SeqCst) {
            return Err("Connect your Spotify library to browse your music.".into());
        }
        let (path, query) = route(request)?;
        if matches!(
            request.kind.as_str(),
            "playlist" | "album" | "artist" | "show"
        ) {
            let collection = match request.kind.as_str() {
                "playlist" => "playlists",
                "album" => "albums",
                "artist" => "artists",
                _ => "shows",
            };
            let header = format!(
                "/{collection}/{}",
                request.id.as_deref().unwrap_or_default()
            );
            let response = tokio::try_join!(
                self.request(Method::GET, &path, query, None),
                self.request(Method::GET, &header, vec![], None)
            );
            let (data, header) = match response {
                Ok(response) => response,
                Err(_) if request.kind == "playlist" => {
                    return tokio::time::timeout(
                        Duration::from_secs(90),
                        super::session_catalog::playlist(
                            &self.session,
                            request,
                            Arc::clone(&self.slots),
                        ),
                    )
                    .await
                    .map_err(|_| "Spotify playlist loading timed out. Retry shortly.")?;
                }
                Err(error) => return Err(error),
            };
            let mut result = page(request, &data);
            result["current"] = item(&header, &request.kind).unwrap_or(Value::Null);
            Ok(result)
        } else {
            let data = self.request(Method::GET, &path, query, None).await?;
            Ok(page(request, &data))
        }
    }

    pub fn track_changed(self: &Arc<Self>, uri: String) {
        *self.current.lock().unwrap_or_else(|p| p.into_inner()) = Some(uri.clone());
        let library = Arc::clone(self);
        tokio::spawn(async move {
            library.saved_status(&uri).await;
        });
    }

    async fn saved_status(&self, uri: &str) {
        let _saved_order = self.saved_state.lock().await;
        if self.ready.load(std::sync::atomic::Ordering::SeqCst)
            && let Ok(result) = self
                .request(
                    Method::GET,
                    "/me/library/contains",
                    vec![("uris", uri.to_owned())],
                    None,
                )
                .await
            && let Some(saved) = result[0].as_bool()
        {
            super::emit(
                json!({"event":"libraryChanged","kind":"savedState","savedUri":uri,"saved":saved}),
            );
        }
    }

    pub fn mutate(
        self: &Arc<Self>,
        kind: &str,
        uri: Option<String>,
        saved: bool,
        name: Option<String>,
    ) {
        let library = Arc::clone(self);
        let kind = kind.to_owned();
        tokio::spawn(async move {
            let _saved_order = if kind == "setSaved" {
                Some(library.saved_state.lock().await)
            } else {
                None
            };
            let result = async {
                let _queue_order = if kind == "queueAdd" {
                    Some(library.queue_writes.lock().await)
                } else {
                    None
                };
                if !library.ready.load(std::sync::atomic::Ordering::SeqCst) {
                    return Err("Connect your Spotify library first.".into());
                }
                if kind == "createPlaylist" {
                    let name = text(name.as_deref().unwrap_or(""), 100);
                    if name.trim().is_empty() {
                        return Err("Enter a playlist name.".into());
                    }
                    return library
                        .request(
                            Method::POST,
                            "/me/playlists",
                            vec![],
                            Some(json!({"name":name,"public":false})),
                        )
                        .await;
                }
                let uri = uri.as_deref().ok_or("A Spotify item is required.")?;
                if !catalog_uri(uri)
                    || (kind == "queueAdd"
                        && !matches!(uri.split(':').nth(1), Some("track" | "episode")))
                {
                    return Err("This Spotify item cannot be used here.".into());
                }
                let (method, path, query) = if kind == "queueAdd" {
                    (
                        Method::POST,
                        "/me/player/queue",
                        vec![
                            ("uri", uri.to_owned()),
                            ("device_id", library.device.clone()),
                        ],
                    )
                } else {
                    (
                        if saved { Method::PUT } else { Method::DELETE },
                        "/me/library",
                        vec![("uris", uri.to_owned())],
                    )
                };
                library.request(method, path, query, None).await
            }
            .await;
            match result {
                Ok(_) => super::emit(
                    json!({"event":"libraryChanged","kind":kind,"savedUri":if kind=="setSaved" { uri } else { None },"saved":if kind=="setSaved" { Some(saved) } else { None }}),
                ),
                Err(error) => {
                    super::emit(json!({"event":"libraryChanged","kind":kind,"error":error}));
                    super::emit(json!({"event":"error","message":error}));
                }
            }
        });
    }
}

fn verify_account(value: &Value, account: &str) -> Result<()> {
    if value["id"].as_str() == Some(account) {
        Ok(())
    } else {
        Err("Use the same Spotify account for playback and your library.".into())
    }
}

async fn decode(mut response: reqwest::Response, method: &Method) -> Result<Value> {
    let status = response.status();
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| "Spotify returned an incomplete response.")?
    {
        if bytes.len().saturating_add(chunk.len()) > 2_000_000 {
            return Err("Spotify returned an oversized library response.".into());
        }
        bytes.extend_from_slice(&chunk);
    }
    if !status.is_success() {
        return Err(match status.as_u16() {
            401 => "Your Spotify library sign-in expired. Disconnect and sign in again.",
            403 => "Spotify does not allow this library request for the current account or app.",
            404 => "This Spotify item is unavailable.",
            429 => "Spotify is rate limiting the library. Try again shortly.",
            _ => "Spotify could not complete this library request. Retry shortly.",
        }
        .into());
    }
    if bytes.is_empty() {
        Ok(Value::Null)
    } else if method != Method::GET {
        Ok(serde_json::from_slice(&bytes).unwrap_or(Value::Null))
    } else {
        serde_json::from_slice(&bytes)
            .map_err(|_| "Spotify returned an invalid library response.".into())
    }
}

fn callback(line: &str, state: &str) -> Option<Result<String>> {
    let mut parts = line.split_whitespace();
    if parts.next()? != "GET" {
        return None;
    }
    let url = Url::parse(&format!("http://127.0.0.1:8989{}", parts.next()?)).ok()?;
    if url.path() != "/login" {
        return None;
    }
    let query: std::collections::HashMap<_, _> = url.query_pairs().into_owned().collect();
    if query.get("state")? != state {
        return None;
    }
    if query.contains_key("error") {
        return Some(Err(
            "Spotify library sign-in was declined. Connect again to retry.".into(),
        ));
    }
    query
        .get("code")
        .filter(|code| !code.is_empty())
        .cloned()
        .map(Ok)
}

fn valid_id(id: &str) -> bool {
    id.len() == 22 && id.bytes().all(|b| b.is_ascii_alphanumeric())
}
pub fn catalog_uri(uri: &str) -> bool {
    let pieces: Vec<_> = uri.split(':').collect();
    pieces.len() == 3
        && pieces[0] == "spotify"
        && ["track", "album", "artist", "playlist", "episode", "show"].contains(&pieces[1])
        && valid_id(pieces[2])
}

fn route(request: &Request) -> Result<(String, Vec<(&'static str, String)>)> {
    if request.request_id.is_empty() || request.request_id.len() > 100 || request.offset > 100_000 {
        return Err("The library request is invalid.".into());
    }
    let mut query = vec![
        ("limit", "20".into()),
        ("offset", request.offset.to_string()),
    ];
    let path = match request.kind.as_str() {
        "playlists" => "/me/playlists".into(),
        "albums" => "/me/albums".into(),
        "shows" => "/me/shows".into(),
        "liked" => "/me/tracks".into(),
        "topTracks" => "/me/top/tracks".into(),
        "topArtists" => "/me/top/artists".into(),
        "recent" => {
            query.retain(|(key, _)| *key != "offset");
            if let Some(cursor) = &request.cursor {
                if cursor.len() > 20 || !cursor.bytes().all(|b| b.is_ascii_digit()) {
                    return Err("The history cursor is invalid.".into());
                }
                query.push(("before", cursor.clone()));
            }
            "/me/player/recently-played".into()
        }
        "artists" => {
            query.retain(|(key, _)| *key != "offset");
            query.push(("type", "artist".into()));
            if let Some(cursor) = &request.cursor {
                if !valid_id(cursor) {
                    return Err("The artist cursor is invalid.".into());
                }
                query.push(("after", cursor.clone()));
            }
            "/me/following".into()
        }
        "queue" => {
            query.clear();
            "/me/player/queue".into()
        }
        "search" => {
            let search = request.query.as_deref().unwrap_or("").trim();
            if search.is_empty() || search.len() > 500 {
                return Err("Enter a search of at most 500 bytes.".into());
            }
            query[0].1 = "5".into();
            query.push(("q", search.into()));
            query.push(("type", "track,album,artist,playlist".into()));
            "/search".into()
        }
        kind @ ("playlist" | "album" | "artist" | "show") => {
            let id = request
                .id
                .as_deref()
                .filter(|id| valid_id(id))
                .ok_or("The Spotify collection ID is invalid.")?;
            let (collection, endpoint) = match kind {
                "playlist" => ("playlists", "items"),
                "album" => ("albums", "tracks"),
                "artist" => ("artists", "albums"),
                _ => ("shows", "episodes"),
            };
            if kind == "artist" {
                query[0].1 = "10".into();
            }
            format!("/{collection}/{id}/{endpoint}")
        }
        _ => return Err("This library view is unsupported.".into()),
    };
    Ok((path, query))
}

fn text(value: &str, limit: usize) -> String {
    value
        .chars()
        .filter(|c| !c.is_control())
        .take(limit)
        .collect()
}
fn field(value: &Value, key: &str, limit: usize) -> Option<String> {
    value[key]
        .as_str()
        .map(|s| text(s, limit))
        .filter(|s| !s.is_empty())
}
fn artwork(value: &Value) -> Option<String> {
    let source = value["images"]
        .as_array()?
        .iter()
        .find_map(|image| image["url"].as_str())?;
    let url = Url::parse(source).ok()?;
    (url.as_str().len() <= 512
        && url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && url.port().is_none()
        && matches!(
            url.host_str(),
            Some(
                "i.scdn.co"
                    | "mosaic.scdn.co"
                    | "image-cdn-fa.spotifycdn.com"
                    | "image-cdn-ak.spotifycdn.com"
            )
        ))
    .then(|| url.to_string())
}
pub(super) fn item(value: &Value, fallback: &str) -> Option<Value> {
    let kind = value["type"].as_str().unwrap_or(fallback);
    let id = value["id"].as_str().filter(|id| valid_id(id))?;
    let uri = format!("spotify:{kind}:{id}");
    if !catalog_uri(&uri) {
        return None;
    }
    let names = value["artists"].as_array().map(|artists| {
        artists
            .iter()
            .filter_map(|a| a["name"].as_str())
            .collect::<Vec<_>>()
            .join(", ")
    });
    let subtitle = names
        .filter(|s| !s.is_empty())
        .or_else(|| field(&value["owner"], "display_name", 120))
        .or_else(|| field(value, "publisher", 120))
        .unwrap_or_else(|| kind.to_owned());
    Some(
        json!({"id":id,"uri":uri,"kind":kind,"title":field(value,"name",100).unwrap_or_default(),"subtitle":text(&subtitle,120),
        "artwork":artwork(value).or_else(|| artwork(&value["album"])),"duration":value["duration_ms"].as_f64().unwrap_or(0.0).clamp(0.0,86_400_000.0)/1000.0,
        "album":field(&value["album"],"name",100),"description":field(value,"description",100),"owner":field(&value["owner"],"display_name",80)}),
    )
}

fn page(request: &Request, data: &Value) -> Value {
    if request.kind == "search" {
        let mut items = Vec::new();
        let mut more = false;
        let mut total = 0;
        for (key, kind) in [
            ("tracks", "track"),
            ("albums", "album"),
            ("artists", "artist"),
            ("playlists", "playlist"),
        ] {
            if let Some(rows) = data[key]["items"].as_array() {
                items.extend(rows.iter().take(5).filter_map(|v| item(v, kind)));
            }
            more |= data[key]["next"].is_string();
            total += data[key]["total"].as_u64().unwrap_or(0);
        }
        return json!({"items":items,"total":total,"nextOffset":more.then_some(request.offset.saturating_add(5))});
    }
    let source = if request.kind == "artists" {
        &data["artists"]
    } else {
        data
    };
    let rows = if request.kind == "queue" {
        data["queue"].as_array()
    } else {
        source["items"].as_array()
    };
    let fallback = match request.kind.as_str() {
        "albums" | "artist" => "album",
        "artists" | "topArtists" => "artist",
        "playlists" => "playlist",
        "shows" => "show",
        "show" => "episode",
        _ => "track",
    };
    let rows = rows.map(Vec::as_slice).unwrap_or(&[]);
    let items: Vec<_> = rows
        .iter()
        .take(20)
        .enumerate()
        .filter_map(|(index, row)| {
            let value = if row["id"].is_string() {
                row
            } else {
                ["item", "track", "album", "show"]
                    .into_iter()
                    .find_map(|key| row[key].is_object().then_some(&row[key]))
                    .unwrap_or(row)
            };
            let mut value = item(value, fallback)?;
            if matches!(request.kind.as_str(), "playlist" | "album" | "show") {
                value["position"] = json!(request.offset.saturating_add(index as u32));
            }
            Some(value)
        })
        .collect();
    let total = source["total"].as_u64();
    let step = if request.kind == "artist" { 10 } else { 20 };
    let next = source["next"].is_string();
    let cursor = if request.kind == "recent" {
        source["cursors"]["before"].as_str()
    } else {
        source["cursors"]["after"].as_str()
    };
    json!({"items":items,"total":total,"nextOffset":(next && !matches!(request.kind.as_str(),"artists"|"recent"|"queue")).then_some(request.offset.saturating_add(step)),
        "nextCursor":if next { cursor.map(|c| text(c,22)) } else { None },"current":item(&data["currently_playing"],"track")})
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(kind: &str) -> Request {
        Request {
            request_id: "sample".into(),
            kind: kind.into(),
            id: None,
            query: None,
            offset: 0,
            cursor: None,
        }
    }

    #[test]
    fn routes_only_supported_endpoints_and_valid_identifiers() {
        assert_eq!(route(&request("liked")).unwrap().0, "/me/tracks");
        assert!(route(&request("https://example.com")).is_err());
        let mut detail = request("playlist");
        detail.id = Some("../../me".into());
        assert!(route(&detail).is_err());
        detail.id = Some("0123456789abcdefghijkl".into());
        assert_eq!(
            route(&detail).unwrap().0,
            "/playlists/0123456789abcdefghijkl/items"
        );
        let mut artists = request("artists");
        artists.cursor = Some("spoof&token=secret".into());
        assert!(route(&artists).is_err());
    }
    #[test]
    fn callback_requires_matching_state_and_path() {
        assert_eq!(
            callback("GET /login?code=sample&state=expected HTTP/1.1", "expected"),
            Some(Ok("sample".into()))
        );
        assert_eq!(
            callback("GET /login?code=sample&state=wrong HTTP/1.1", "expected"),
            None
        );
        assert_eq!(
            callback(
                "GET /favicon.ico?code=sample&state=expected HTTP/1.1",
                "expected"
            ),
            None
        );
        assert!(
            callback(
                "GET /login?error=access_denied&state=expected HTTP/1.1",
                "expected"
            )
            .unwrap()
            .is_err()
        );
    }
    #[test]
    fn verifies_the_library_grant_belongs_to_the_native_account() {
        assert!(verify_account(&json!({"id":"sample-account"}), "sample-account").is_ok());
        assert!(verify_account(&json!({"id":"other-account"}), "sample-account").is_err());
        assert!(verify_account(&Value::Null, "sample-account").is_err());
    }
    #[test]
    fn refresh_preserves_the_previous_refresh_token() {
        let previous = Grant {
            access_token: "old".into(),
            refresh_token: "reusable".into(),
            expires_at: 0,
            account: "sample".into(),
        };
        let response: Token = serde_json::from_value(
            json!({"access_token":"fresh","token_type":"Bearer","expires_in":3600}),
        )
        .unwrap();
        let fresh = Grant::renewed(response, Some(&previous), "sample".into()).unwrap();
        assert_eq!(fresh.refresh_token, "reusable");
        assert_eq!(fresh.access_token, "fresh");
        assert!(fresh.expires_at > now());
    }
    #[test]
    fn pages_preserve_pagination_when_unavailable_items_are_skipped() {
        let track = json!({"id":"0123456789abcdefghijkl","type":"track","name":"Sample song","duration_ms":150000,"artists":[{"name":"Sample artist"}]});
        let result = page(
            &request("playlist"),
            &json!({"items":[{"item":track},{"track":null}],"next":"https://api.spotify.com/next","total":21}),
        );
        assert_eq!(result["items"].as_array().unwrap().len(), 1);
        assert_eq!(result["nextOffset"], 20);
        assert_eq!(result["items"][0]["duration"], 150.0);
    }
    #[test]
    fn collection_positions_preserve_null_slots_and_duplicate_tracks() {
        let track = json!({"id":"0123456789abcdefghijkl","type":"track","name":"Sample song"});
        let mut detail = request("playlist");
        detail.offset = 40;
        let result = page(
            &detail,
            &json!({"items":[{"item":null},{"item":track},{"item":track}],"total":43}),
        );
        assert_eq!(result["items"].as_array().unwrap().len(), 2);
        assert_eq!(result["items"][0]["position"], 41);
        assert_eq!(result["items"][1]["position"], 42);
    }
    #[test]
    fn search_is_bounded_and_preserves_all_result_types() {
        let value = json!({"id":"0123456789abcdefghijkl","name":"Sample"});
        let rows = vec![value; 50];
        let result = page(
            &request("search"),
            &json!({"tracks":{"items":rows},"albums":{"items":rows},"artists":{"items":rows},"playlists":{"items":rows}}),
        );
        assert_eq!(result["items"].as_array().unwrap().len(), 20);
        assert_eq!(result["items"][10]["kind"], "artist");
    }
    #[test]
    fn artwork_and_text_cannot_expand_the_protocol_without_bound() {
        let value = json!({"id":"0123456789abcdefghijkl","type":"track","name":"😀".repeat(5000),"description":"😀".repeat(5000),"album":{"name":"😀".repeat(5000)},"artists":[{"name":"😀".repeat(5000)}],"images":[{"url":"https://evil.example/cover"}]});
        let rows = vec![value; 20];
        let result = page(&request("album"), &json!({"items":rows}));
        assert!(serde_json::to_vec(&result).unwrap().len() < 60000);
        assert!(result["items"][0]["artwork"].is_null());
        let expanded = format!("https://i.scdn.co/image/{}", "😀".repeat(100));
        assert!(expanded.len() < 512);
        assert!(Url::parse(&expanded).unwrap().as_str().len() > 512);
        assert!(artwork(&json!({"images":[{"url":expanded}]})).is_none());
    }

    #[test]
    fn top_tracks_and_queue_keep_tracks_instead_of_their_nested_album() {
        let track = json!({"id":"0123456789abcdefghijkl","type":"track","name":"Sample song","album":{"id":"abcdefghijkl0123456789","type":"album","name":"Sample album"}});
        for kind in ["topTracks", "queue"] {
            let data = if kind == "queue" {
                json!({"queue":[track]})
            } else {
                json!({"items":[track]})
            };
            let result = page(&request(kind), &data);
            assert_eq!(result["items"][0]["kind"], "track");
            assert_eq!(result["items"][0]["title"], "Sample song");
        }
    }
    async fn response(body: String) -> reqwest::Response {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let _ = stream.read(&mut request).await;
            let header = format!(
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(header.as_bytes()).await.unwrap();
            let _ = stream.write_all(body.as_bytes()).await;
        });
        Client::new().get(url).send().await.unwrap()
    }
    #[tokio::test]
    async fn cancelling_authorization_closes_the_callback_listener() {
        let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = reserved.local_addr().unwrap().to_string();
        drop(reserved);
        let bound_address = address.clone();
        let (started, began) = tokio::sync::oneshot::channel();
        let authorization = tokio::spawn(async move {
            let http = Client::new();
            authorize_with(oauth(), &http, &bound_address, &["streaming"], move |_| {
                let _ = started.send(());
                Ok(())
            })
            .await
        });
        began.await.unwrap();
        assert!(TcpListener::bind(&address).await.is_err());
        authorization.abort();
        assert!(authorization.await.unwrap_err().is_cancelled());
        assert!(TcpListener::bind(&address).await.is_ok());
    }

    #[tokio::test]
    async fn successful_mutations_use_status_but_reads_require_valid_json() {
        assert!(
            decode(response("accepted".into()).await, &Method::POST)
                .await
                .is_ok()
        );
        assert!(
            decode(response("accepted".into()).await, &Method::GET)
                .await
                .is_err()
        );
        assert!(
            decode(response("x".repeat(2_000_001)).await, &Method::GET)
                .await
                .is_err()
        );
    }
}
