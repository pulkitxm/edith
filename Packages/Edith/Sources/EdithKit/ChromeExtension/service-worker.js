const defaults = {
  port: 52728,
  token: "",
  profile: "Default",
  idleThreshold: 300,
  enabled: true,
  mediaEnabled: false
}

let sending = false
let queued = false
let lastSentAt = Date.now()

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

async function heartbeat() {
  if (sending) {
    queued = true
    return
  }
  sending = true
  try {
    const settings = await config()
    if (!settings.enabled || !settings.token) {
      await chrome.storage.local.set({ connectionStatus: "setup", lastError: "Finish setup in extension settings." })
      return
    }
    const tab = await activeTab()
    if (!tab || !tab.url || !/^https?:/.test(tab.url)) return
    const idle = await chrome.idle.queryState(Number(settings.idleThreshold))
    const now = Date.now()
    const duration = Math.max(1, Math.min(120, (now - lastSentAt) / 1000))
    lastSentAt = now
    const parsed = new URL(tab.url)
    const payload = {
      timestamp: new Date(now - duration * 1000).toISOString(),
      duration,
      presence: idle === "active" ? "active" : idle === "locked" ? "locked" : "idle",
      appName: browserName(),
      url: tab.url,
      domain: parsed.hostname,
      title: tab.title || null,
      faviconURL: tab.favIconUrl || null,
      browserProfile: settings.profile,
      media: await mediaFor(tab.id, settings.mediaEnabled)
    }
    const response = await fetch(`http://127.0.0.1:${settings.port}/v1/heartbeat`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Edith-Token": settings.token },
      body: JSON.stringify(payload)
    })
    if (!response.ok) throw new Error(`Edith returned ${response.status}`)
    await chrome.storage.local.set({ connectionStatus: "connected", lastConnectedAt: new Date().toISOString(), lastError: "" })
  } catch (error) {
    await chrome.storage.local.set({ connectionStatus: "offline", lastError: String(error.message || error) })
  } finally {
    sending = false
    if (queued) {
      queued = false
      setTimeout(heartbeat, 250)
    }
  }
}

function scheduleHeartbeat() {
  setTimeout(heartbeat, 200)
}

chrome.runtime.onInstalled.addListener(async details => {
  await chrome.alarms.create("attention-heartbeat", { periodInMinutes: 0.5 })
  if (details.reason === "install") chrome.runtime.openOptionsPage()
  scheduleHeartbeat()
})

chrome.runtime.onStartup.addListener(async () => {
  await chrome.alarms.create("attention-heartbeat", { periodInMinutes: 0.5 })
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
  if (message.type !== "edith-media" || sender.tab?.id == null) return
  chrome.storage.session.set({ [`media:${sender.tab.id}`]: message.media || [] })
  scheduleHeartbeat()
})
