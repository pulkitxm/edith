const defaults = {
  port: 52728,
  token: "",
  profile: "Default",
  idleThreshold: 300,
  enabled: true
}

const segmentLimit = 30 * 60 * 1000
const healthInterval = 5 * 60 * 1000
const searchHosts = ["google.", "bing.com", "duckduckgo.com", "kagi.com", "search.brave.com", "perplexity.ai", "ecosia.org"]
const githubReserved = new Set(["settings", "notifications", "orgs", "marketplace", "explore", "topics", "search", "login", "sponsors", "features", "pulls", "issues", "new", "codespaces", "dashboard", "trending", "collections", "enterprise", "pricing", "about", "apps", "copilot"])

let work = Promise.resolve()

async function config() {
  return { ...defaults, ...(await chrome.storage.local.get(defaults)) }
}

function browserName() {
  const brands = navigator.userAgentData?.brands?.map(entry => entry.brand).join(" ") || ""
  const agent = `${brands} ${navigator.userAgent}`
  if (agent.includes("Dia")) return "Dia"
  if (agent.includes("Arc")) return "Arc"
  if (agent.includes("Edg/") || agent.includes("Microsoft Edge")) return "Microsoft Edge"
  if (agent.includes("OPR/") || agent.includes("Opera")) return "Opera"
  if (agent.includes("Brave")) return "Brave"
  if (agent.includes("Vivaldi")) return "Vivaldi"
  if (agent.includes("Chrome/")) return "Google Chrome"
  return "Chromium browser"
}

async function focusedWindowID() {
  const stored = await chrome.storage.session.get("attentionFocusedWindow")
  return stored.attentionFocusedWindow
}

async function rememberFocus(windowID) {
  await chrome.storage.session.set({ attentionFocusedWindow: windowID })
}

async function activeTab() {
  const tracked = await focusedWindowID()
  if (tracked === chrome.windows.WINDOW_ID_NONE) return null
  const window = await chrome.windows.getLastFocused()
  if (!window.focused || window.id === chrome.windows.WINDOW_ID_NONE) return null
  if (tracked !== undefined && tracked !== window.id) return null
  const tabs = await chrome.tabs.query({ active: true, windowId: window.id })
  return tabs[0] || null
}

async function pageFor(tabId) {
  if (tabId == null) return {}
  const key = `page:${tabId}`
  const stored = await chrome.storage.session.get(key)
  return stored[key] || {}
}

function param(url, names) {
  for (const name of names) {
    const value = url.searchParams.get(name)
    if (value && value.trim()) return value.trim().slice(0, 200)
  }
  return null
}

function urlTags(raw) {
  const tags = {}
  let url
  try {
    url = new URL(raw)
  } catch {
    return tags
  }
  const host = url.hostname.replace(/^www\./, "").toLowerCase()
  const parts = url.pathname.split("/").filter(Boolean)
  if (searchHosts.some(entry => host.includes(entry)) || /(^|\/)search/.test(url.pathname) || host.endsWith("youtube.com") && parts[0] === "results") {
    const search = param(url, ["q", "query", "search_query", "k", "text", "p"])
    if (search) tags.search = search
  }
  if (host === "github.com" && parts.length >= 2 && !githubReserved.has(parts[0])) {
    tags.repo = `${parts[0]}/${parts[1]}`.toLowerCase()
    tags.section = parts[2] || "code"
  }
  if (host.endsWith("youtube.com")) {
    if (parts[0] === "watch") {
      const video = param(url, ["v"])
      if (video) tags.video = video
      tags.section = "watch"
    } else if (parts[0] === "shorts") {
      if (parts[1]) tags.video = parts[1]
      tags.section = "shorts"
    } else if (parts[0]?.startsWith("@")) {
      tags.channel = parts[0]
      tags.section = "channel"
    } else {
      tags.section = parts[0] || "home"
    }
  }
  if (host === "youtu.be" && parts[0]) {
    tags.video = parts[0]
    tags.section = "watch"
  }
  if (host === "x.com" || host === "twitter.com") {
    if (parts[1] === "status") {
      tags.channel = `@${parts[0]}`
      tags.section = "post"
    } else {
      tags.section = parts[0] || "home"
    }
  }
  if (host.endsWith("reddit.com") && parts[0] === "r" && parts[1]) {
    tags.channel = `r/${parts[1]}`
    tags.section = parts[2] === "comments" ? "thread" : "subreddit"
  }
  if (host.endsWith("twitch.tv") && parts[0]) tags.channel = parts[0]
  if (host === "meet.google.com" && /^[a-z]{3}-[a-z]{4}-[a-z]{3}$/.test(parts[0] || "")) tags.section = "call"
  return tags
}

async function groupTitle(tab) {
  if (tab.groupId == null || tab.groupId < 0 || !chrome.tabGroups?.get) return null
  try {
    const group = await chrome.tabGroups.get(tab.groupId)
    return group.title || group.color || null
  } catch {
    return null
  }
}

async function tabCount() {
  try {
    return (await chrome.tabs.query({})).length
  } catch {
    return null
  }
}

async function observe(settings) {
  const tab = await activeTab()
  if (!tab?.url || !/^https?:/.test(tab.url) || tab.incognito) return null
  const idle = await chrome.idle.queryState(Number(settings.idleThreshold))
  const page = await pageFor(tab.id)
  const media = Array.isArray(page.media) ? page.media : []
  const tags = { ...urlTags(tab.url), ...(page.tags || {}) }
  const group = await groupTitle(tab)
  if (group) tags.group = group
  let presence = idle === "active" ? "active" : idle === "locked" ? "locked" : "idle"
  if (presence === "idle" && (media.some(item => item.playing && item.kind === "video") || tab.audible)) {
    presence = "active"
    tags.passive = media.some(item => item.kind === "video") ? "video" : "audio"
  }
  const observation = {
    tabId: tab.id,
    timestamp: Date.now(),
    presence,
    appName: browserName(),
    url: tab.url,
    domain: new URL(tab.url).hostname,
    title: tab.title || null,
    faviconURL: tab.favIconUrl || null,
    browserProfile: settings.profile,
    media,
    tags,
    tabs: await tabCount()
  }
  observation.identity = JSON.stringify([
    observation.presence,
    observation.url,
    observation.title,
    media.map(item => [item.title, item.kind, item.playing]),
    Object.entries(tags).sort()
  ])
  return observation
}

async function takeSignals(tabId) {
  if (tabId == null) return null
  const key = `signals:${tabId}`
  const stored = await chrome.storage.session.get(key)
  await chrome.storage.session.remove(key)
  return stored[key] || null
}

function addSignals(left, right) {
  if (!right) return left
  const base = left || { keys: 0, clicks: 0, scrolls: 0 }
  return {
    keys: base.keys + (right.keys || 0),
    clicks: base.clicks + (right.clicks || 0),
    scrolls: base.scrolls + (right.scrolls || 0),
    tabs: Math.max(base.tabs || 0, right.tabs || 0) || undefined
  }
}

function payloadFor(previous, segment) {
  const { tabId, identity, tabs, timestamp, ...fields } = previous
  return {
    ...fields,
    id: segment.id,
    timestamp: new Date(segment.startedAt).toISOString(),
    duration: (segment.endedAt - segment.startedAt) / 1000,
    signals: segment.signals || undefined
  }
}

async function audibleSegments(now, activeTabId, elapsed) {
  const { attentionAudible = {} } = await chrome.storage.session.get("attentionAudible")
  let tabs = []
  try {
    tabs = (await chrome.tabs.query({ audible: true })).filter(tab => tab.audible === true && tab.id !== activeTabId && /^https?:/.test(tab.url || "") && !tab.incognito)
  } catch {
    tabs = []
  }
  const next = {}
  const entries = []
  for (const tab of tabs) {
    const key = `${tab.id}|${tab.url}|${tab.title}`
    const existing = attentionAudible[tab.id]
    const segment = existing && existing.key === key && now - existing.lastSeen <= 60000 && now - existing.startedAt < segmentLimit
      ? { ...existing, lastSeen: now }
      : { id: crypto.randomUUID(), key, startedAt: now - Math.min(elapsed, 60) * 1000, lastSeen: now }
    next[tab.id] = segment
    if (segment.lastSeen > segment.startedAt) {
      entries.push({
        id: segment.id,
        timestamp: new Date(segment.startedAt).toISOString(),
        duration: (segment.lastSeen - segment.startedAt) / 1000,
        title: tab.title || new URL(tab.url).hostname,
        url: tab.url,
        domain: new URL(tab.url).hostname,
        kind: "audio"
      })
    }
  }
  await chrome.storage.session.set({ attentionAudible: next })
  return entries
}

async function enqueue(payload) {
  const { attentionQueue = [], attentionDroppedEvents = 0 } = await chrome.storage.local.get({ attentionQueue: [], attentionDroppedEvents: 0 })
  const next = [...attentionQueue.filter(item => item.id !== payload.id), payload]
  if (next.length <= 4096 && new TextEncoder().encode(JSON.stringify(next)).length <= 4 * 1024 * 1024) {
    await chrome.storage.local.set({ attentionQueue: next })
  } else {
    await chrome.storage.local.set({ attentionDroppedEvents: attentionDroppedEvents + 1 })
  }
}

async function capture() {
  const settings = await config()
  if (!settings.enabled || !settings.token) {
    await chrome.storage.session.set({ attentionPrevious: null, attentionSegment: null })
    await chrome.storage.local.set({ connectionStatus: "setup", lastError: "Finish setup in extension settings." })
    return
  }
  const current = await observe(settings)
  const now = Date.now()
  const { attentionPrevious: previous, attentionSegment: stored } = await chrome.storage.session.get(["attentionPrevious", "attentionSegment"])
  const elapsed = previous ? (now - previous.timestamp) / 1000 : 0
  let segment = null
  let payload = null
  if (previous && elapsed > 0 && elapsed <= 60) {
    const signals = addSignals(await takeSignals(previous.tabId), previous.tabs ? { tabs: previous.tabs } : null)
    if (stored && stored.identity === previous.identity && stored.endedAt === previous.timestamp && now - stored.startedAt <= segmentLimit) {
      segment = { ...stored, endedAt: now, signals: addSignals(stored.signals, signals) }
    } else {
      segment = { id: crypto.randomUUID(), identity: previous.identity, startedAt: previous.timestamp, endedAt: now, signals }
    }
    payload = payloadFor(previous, segment)
  }
  const audible = await audibleSegments(now, current?.tabId ?? previous?.tabId, elapsed)
  if (payload) {
    if (audible.length) payload.audible = audible
    await enqueue(payload)
  } else if (audible.length) {
    await enqueue({
      id: crypto.randomUUID(),
      timestamp: new Date(now).toISOString(),
      duration: 0,
      presence: "active",
      appName: browserName(),
      browserProfile: settings.profile,
      media: [],
      audible
    })
  }
  await chrome.storage.session.set({ attentionPrevious: current, attentionSegment: segment })
  return settings
}

async function checkHealth(settings, force) {
  const { lastHealthCheck = 0 } = await chrome.storage.session.get("lastHealthCheck")
  if (!force && Date.now() - lastHealthCheck < healthInterval) return
  const response = await fetch(`http://127.0.0.1:${settings.port}/v1/health`, {
    signal: AbortSignal.timeout(5000)
  })
  if (!response.ok) throw new Error(`Edith returned ${response.status}`)
  await chrome.storage.session.set({ lastHealthCheck: Date.now() })
  const body = typeof response.json === "function" ? await response.json().catch(() => ({})) : {}
  const expected = body?.extension
  const running = chrome.runtime.getManifest?.().version
  if (expected && running && expected !== running && chrome.runtime.reload) {
    await chrome.storage.local.set({ lastError: `Updating to ${expected}` })
    chrome.runtime.reload()
  }
}

async function flush(settings) {
  const { attentionQueue = [] } = await chrome.storage.local.get("attentionQueue")
  if (!attentionQueue.length) await checkHealth(settings, true)
  for (let count = 0; attentionQueue.length && count < 32; count++) {
    const response = await fetch(`http://127.0.0.1:${settings.port}/v1/heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Edith-Token": settings.token },
      body: JSON.stringify(attentionQueue[0]),
      signal: AbortSignal.timeout(5000)
    })
    if (!response.ok) throw new Error(`Edith returned ${response.status}`)
    attentionQueue.shift()
    await chrome.storage.local.set({ attentionQueue })
  }
  await checkHealth(settings, false)
  const { attentionDroppedEvents = 0 } = await chrome.storage.local.get("attentionDroppedEvents")
  await chrome.storage.local.set({
    connectionStatus: "connected",
    lastConnectedAt: new Date().toISOString(),
    lastError: attentionDroppedEvents ? `${attentionDroppedEvents} intervals were not retained because storage was full.` : ""
  })
}

function heartbeat() {
  work = work.catch(() => {}).then(async () => {
    try {
      const settings = await capture()
      if (settings) await flush(settings)
    } catch (error) {
      await chrome.storage.local.set({ connectionStatus: "offline", lastError: String(error.message || error) })
    }
  })
  return work
}

function scheduleHeartbeat() {
  void heartbeat()
}

function ensureHeartbeatAlarm() {
  chrome.alarms.get("attention-heartbeat", alarm => {
    if (!alarm) chrome.alarms.create("attention-heartbeat", { periodInMinutes: 0.5 })
  })
}

async function recordPage(tabId, message) {
  const key = `page:${tabId}`
  const signalsKey = `signals:${tabId}`
  const stored = await chrome.storage.session.get([key, signalsKey])
  const page = { ...(stored[key] || {}) }
  if (Array.isArray(message.media)) page.media = message.media
  if (message.tags && typeof message.tags === "object") page.tags = message.tags
  const updates = { [key]: page }
  if (message.signals) updates[signalsKey] = addSignals(stored[signalsKey], message.signals)
  await chrome.storage.session.set(updates)
}

chrome.runtime.onInstalled.addListener(details => {
  ensureHeartbeatAlarm()
  if (details.reason === "install") chrome.runtime.openOptionsPage()
  scheduleHeartbeat()
})

chrome.runtime.onStartup.addListener(() => {
  ensureHeartbeatAlarm()
  scheduleHeartbeat()
})

chrome.alarms.onAlarm.addListener(alarm => {
  if (alarm.name === "attention-heartbeat") heartbeat()
})

chrome.tabs.onActivated.addListener(scheduleHeartbeat)
chrome.tabs.onUpdated.addListener((tabId, change) => {
  if (change.url || change.status === "complete" || change.title || change.audible !== undefined) scheduleHeartbeat()
})
chrome.tabs.onRemoved.addListener(tabId => chrome.storage.session.remove([`page:${tabId}`, `signals:${tabId}`]))
chrome.windows.onFocusChanged.addListener(windowID => {
  work = work.catch(() => {}).then(() => rememberFocus(windowID))
  scheduleHeartbeat()
})
chrome.idle.onStateChanged.addListener(scheduleHeartbeat)

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type === "edith-heartbeat-now") {
    scheduleHeartbeat()
    return
  }
  if (message.type !== "edith-page" || sender.tab?.id == null) return
  work = work.catch(() => {}).then(() => recordPage(sender.tab.id, message))
  if (message.changed) scheduleHeartbeat()
})

ensureHeartbeatAlarm()
