const defaults = {
  port: 52728,
  token: "",
  profile: "Default",
  idleThreshold: 300,
  enabled: true,
  mediaEnabled: false
}

let work = Promise.resolve()

async function config() {
  return { ...defaults, ...(await chrome.storage.local.get(defaults)) }
}

function browserName() {
  const agent = navigator.userAgent
  if (agent.includes("Edg/")) return "Microsoft Edge"
  if (agent.includes("OPR/")) return "Opera"
  if (agent.includes("Brave")) return "Brave"
  if (agent.includes("Dia/")) return "Dia"
  if (agent.includes("Chrome/")) return "Google Chrome"
  return "Chromium browser"
}

async function activeTab() {
  const window = await chrome.windows.getLastFocused()
  if (!window.focused || window.id === chrome.windows.WINDOW_ID_NONE) return null
  const tabs = await chrome.tabs.query({ active: true, windowId: window.id })
  return tabs[0] || null
}

async function mediaFor(tabId, enabled) {
  if (!enabled || tabId == null) return []
  const key = `media:${tabId}`
  const stored = await chrome.storage.session.get(key)
  return Array.isArray(stored[key]) ? stored[key] : []
}

async function observe(settings) {
  const tab = await activeTab()
  if (!tab?.url || !/^https?:/.test(tab.url)) return null
  const idle = await chrome.idle.queryState(Number(settings.idleThreshold))
  return {
    id: crypto.randomUUID(),
    timestamp: Date.now(),
    presence: idle === "active" ? "active" : idle === "locked" ? "locked" : "idle",
    appName: browserName(),
    url: tab.url,
    domain: new URL(tab.url).hostname,
    title: tab.title || null,
    faviconURL: tab.favIconUrl || null,
    browserProfile: settings.profile,
    media: await mediaFor(tab.id, settings.mediaEnabled)
  }
}

async function capture() {
  const settings = await config()
  if (!settings.enabled || !settings.token) {
    await chrome.storage.session.set({ attentionPrevious: null })
    await chrome.storage.local.set({ connectionStatus: "setup", lastError: "Finish setup in extension settings." })
    return
  }
  const current = await observe(settings)
  const now = Date.now()
  const { attentionPrevious: previous } = await chrome.storage.session.get("attentionPrevious")
  const { attentionQueue = [], attentionDroppedEvents = 0 } = await chrome.storage.local.get({ attentionQueue: [], attentionDroppedEvents: 0 })
  const elapsed = previous ? (now - previous.timestamp) / 1000 : 0
  if (previous && elapsed > 0 && elapsed <= 60) {
    const payload = {
      ...previous,
      id: previous.id,
      timestamp: new Date(previous.timestamp).toISOString(),
      duration: elapsed
    }
    const next = [...attentionQueue, payload]
    if (next.length <= 4096 && new TextEncoder().encode(JSON.stringify(next)).length <= 4 * 1024 * 1024) {
      await chrome.storage.local.set({ attentionQueue: next })
    } else {
      await chrome.storage.local.set({ attentionDroppedEvents: attentionDroppedEvents + 1 })
    }
  }
  await chrome.storage.session.set({ attentionPrevious: current })
  return settings
}

async function flush(settings) {
  const { attentionQueue = [] } = await chrome.storage.local.get("attentionQueue")
  if (!attentionQueue.length) {
    const response = await fetch(`http://127.0.0.1:${settings.port}/v1/health`, {
      signal: AbortSignal.timeout(5000)
    })
    if (!response.ok) throw new Error(`Edith returned ${response.status}`)
  }
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
  if (change.url || change.status === "complete") scheduleHeartbeat()
})
chrome.tabs.onRemoved.addListener(tabId => chrome.storage.session.remove(`media:${tabId}`))
chrome.windows.onFocusChanged.addListener(scheduleHeartbeat)
chrome.idle.onStateChanged.addListener(scheduleHeartbeat)

chrome.runtime.onMessage.addListener((message, sender) => {
  if (message.type === "edith-heartbeat-now") {
    scheduleHeartbeat()
    return
  }
  if (message.type !== "edith-media" || sender.tab?.id == null) return
  chrome.storage.session.set({ [`media:${sender.tab.id}`]: message.media || [] })
  scheduleHeartbeat()
})

ensureHeartbeatAlarm()
