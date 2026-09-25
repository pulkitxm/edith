const counters = { keys: 0, clicks: 0, scrolls: 0 }
let lastScroll = 0
let lastSignature = ""

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
  if (location.hostname.endsWith("youtube.com")) {
    const channel = document.querySelector("ytd-watch-metadata ytd-channel-name a, #owner #channel-name a, ytd-reel-player-overlay-renderer #channel-name a")
    const name = text(channel?.textContent) || text(document.querySelector('span[itemprop="author"] link[itemprop="name"]')?.getAttribute("content"))
    if (name) tags.channel = name
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
  const signature = JSON.stringify([media.map(item => [item.title, item.kind]), tags])
  const changed = signature !== lastSignature
  const active = counters.keys || counters.clicks || counters.scrolls
  if (!force && !changed && !active) return
  lastSignature = signature
  const signals = active ? { ...counters } : null
  counters.keys = 0
  counters.clicks = 0
  counters.scrolls = 0
  chrome.runtime.sendMessage({ type: "edith-page", media, tags, signals, changed }).catch(() => {})
}

document.addEventListener("keydown", () => { counters.keys += 1 }, { capture: true, passive: true })
document.addEventListener("pointerdown", () => { counters.clicks += 1 }, { capture: true, passive: true })
document.addEventListener("wheel", () => {
  const now = Date.now()
  if (now - lastScroll > 250) {
    counters.scrolls += 1
    lastScroll = now
  }
}, { capture: true, passive: true })
for (const name of ["play", "pause", "ended", "loadedmetadata"]) {
  document.addEventListener(name, () => publish(true), true)
}
document.addEventListener("visibilitychange", () => publish(true))
setInterval(() => publish(false), 10000)
publish(true)
