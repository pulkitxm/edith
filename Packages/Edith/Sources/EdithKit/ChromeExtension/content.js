const counters = { keys: 0, clicks: 0, scrolls: 0 }
let lastScroll = 0
let lastSignature = ""
let lastInputAt = Date.now()
let publishedInputAt = 0
let inputResumed = false

function text(value) {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, 300) : null
}

function mediaItems() {
  const metadata = navigator.mediaSession?.metadata
  return Array.from(document.querySelectorAll("audio,video"))
    .filter(element => !element.paused && !element.ended && element.readyState > 1)
    .map(element => ({
      title: text(metadata?.title) || text(element.getAttribute("title")) || text(document.title) || "Unknown media",
      artist: text(metadata?.artist),
      album: text(metadata?.album),
      service: location.hostname,
      kind: element.tagName.toLowerCase() === "audio" || element.videoWidth === 0 ? "audio" : "video",
      playing: true
    }))
}

function pageTags() {
  const tags = {}
  if (location.hostname.endsWith("youtube.com") && ["/watch", "/shorts/"].some(path => location.pathname.startsWith(path))) {
    const channel = document.querySelector("ytd-watch-metadata ytd-channel-name a, #owner #channel-name a, ytd-reel-player-overlay-renderer #channel-name a")
    const name = text(channel?.textContent) || text(document.querySelector('span[itemprop="author"] link[itemprop="name"]')?.getAttribute("content"))
    const currentVideo = new URL(location.href).searchParams.get("v")
    const renderedVideo = document.querySelector("ytd-watch-flexy[video-id]")?.getAttribute("video-id")
    if (name && (!currentVideo || renderedVideo === currentVideo)) tags.channel = name
  }
  if (location.hostname === "github.com") {
    const title = text(document.querySelector(".js-issue-title, bdi.js-issue-title, [data-testid='issue-title']")?.textContent)
    if (title) tags.doc = title
  }
  const site = text(document.querySelector('meta[property="og:site_name"]')?.getAttribute("content"))
  if (site) tags.site = site
  const about = text(document.querySelector('meta[name="description"], meta[property="og:description"]')?.getAttribute("content"))
  if (about) tags.about = about.slice(0, 200)
  return tags
}

function publish(force) {
  if (!chrome.runtime?.id) return
  const media = mediaItems()
  const tags = pageTags()
  const signature = JSON.stringify([location.href, document.title, media.map(item => [item.title, item.kind]), tags])
  const changed = signature !== lastSignature
  const active = counters.keys || counters.clicks || counters.scrolls
  const inputChanged = lastInputAt !== publishedInputAt
  if (!force && !changed && !active && !inputChanged) return
  lastSignature = signature
  const signals = active ? { ...counters } : null
  publishedInputAt = lastInputAt
  const resumed = inputResumed
  inputResumed = false
  counters.keys = 0
  counters.clicks = 0
  counters.scrolls = 0
  chrome.runtime.sendMessage({ type: "edith-page", url: location.href, title: document.title, media, tags, signals, changed, lastInputAt, inputResumed: resumed }).catch(() => {})
}

function recordInput(event, counter) {
  if (!event.isTrusted || document.visibilityState !== "visible" || !document.hasFocus()) return
  const now = Date.now()
  inputResumed ||= now - lastInputAt >= 10000
  lastInputAt = now
  if (counter === "scrolls") {
    if (now - lastScroll > 250) {
      counters.scrolls += 1
      lastScroll = now
    }
  } else if (counter) {
    counters[counter] += 1
  }
  if (inputResumed) publish(false)
}

for (const [name, counter] of [["keydown", "keys"], ["pointerdown", "clicks"], ["wheel", "scrolls"], ["pointermove", null], ["touchmove", null]]) {
  document.addEventListener(name, event => recordInput(event, counter), { capture: true, passive: true })
}
for (const name of ["play", "pause", "ended", "loadedmetadata"]) {
  document.addEventListener(name, () => publish(true), true)
}
document.addEventListener("visibilitychange", () => publish(true))
setInterval(() => publish(false), 10000)
publish(true)
