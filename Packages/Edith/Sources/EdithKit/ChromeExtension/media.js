function text(value) {
  return typeof value === "string" && value.trim() ? value.trim() : null
}

function metadataFor(element) {
  const metadata = navigator.mediaSession?.metadata
  const title = text(metadata?.title) || text(element.getAttribute("title")) || text(document.title) || "Unknown media"
  const artist = text(metadata?.artist)
  const album = text(metadata?.album)
  return {
    title,
    artist,
    album,
    service: location.hostname,
    kind: element.tagName.toLowerCase() === "audio" ? "audio" : "video",
    playing: !element.paused && !element.ended && element.readyState > 1
  }
}

function publish() {
  const media = Array.from(document.querySelectorAll("audio,video"))
    .map(metadataFor)
    .filter(item => item.playing)
  chrome.runtime.sendMessage({ type: "edith-media", media }).catch(() => {})
}

document.addEventListener("play", publish, true)
document.addEventListener("pause", publish, true)
document.addEventListener("ended", publish, true)
document.addEventListener("loadedmetadata", publish, true)
setInterval(publish, 15000)
publish()
