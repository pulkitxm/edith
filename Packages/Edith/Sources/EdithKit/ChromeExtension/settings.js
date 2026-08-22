const fields = ["profile", "port", "token", "idleThreshold", "enabled"]
const defaults = { profile: "Default", port: 52728, token: "", idleThreshold: 300, enabled: true, mediaEnabled: false }

async function load() {
  const values = { ...defaults, ...(await chrome.storage.local.get(defaults)) }
  for (const id of fields) {
    const field = document.getElementById(id)
    field[field.type === "checkbox" ? "checked" : "value"] = values[id]
    field.addEventListener("change", save)
    if (field.type !== "checkbox") field.addEventListener("input", save)
  }
  await renderDeep()
  await renderStatus(values)
}

let saveTimer
function save() {
  clearTimeout(saveTimer)
  saveTimer = setTimeout(async () => {
    const values = {}
    for (const id of fields) {
      const field = document.getElementById(id)
      values[id] = field.type === "checkbox" ? field.checked : field.type === "number" || id === "idleThreshold" ? Number(field.value) : field.value.trim()
    }
    await chrome.storage.local.set(values)
    const saved = document.getElementById("saved")
    saved.textContent = "Saved"
    setTimeout(() => { saved.textContent = "Changes save automatically" }, 1200)
  }, 250)
}

async function renderStatus(values = null) {
  const state = values || await chrome.storage.local.get(["connectionStatus", "lastConnectedAt", "lastError"])
  const status = document.getElementById("status")
  const connected = state.connectionStatus === "connected"
  status.textContent = connected ? "Connected" : state.connectionStatus === "offline" ? "Edith offline" : "Setup needed"
  status.className = `status ${connected ? "good" : "warn"}`
  status.title = state.lastError || state.lastConnectedAt || ""
}

async function renderDeep() {
  const allowed = await chrome.permissions.contains({ origins: ["http://*/*", "https://*/*"] })
  const button = document.getElementById("deep")
  button.textContent = allowed ? "Disable deep mode" : "Enable deep mode"
  button.className = allowed ? "active" : ""
  await chrome.storage.local.set({ mediaEnabled: allowed })
}

async function toggleDeep() {
  const origins = ["http://*/*", "https://*/*"]
  const allowed = await chrome.permissions.contains({ origins })
  if (allowed) {
    await chrome.scripting.unregisterContentScripts({ ids: ["edith-media"] }).catch(() => {})
    await chrome.permissions.remove({ origins })
  } else {
    const granted = await chrome.permissions.request({ origins })
    if (granted) {
      await chrome.scripting.unregisterContentScripts({ ids: ["edith-media"] }).catch(() => {})
      await chrome.scripting.registerContentScripts([{ id: "edith-media", matches: origins, js: ["media.js"], runAt: "document_idle", persistAcrossSessions: true }])
    }
  }
  await renderDeep()
}

async function testConnection(interactive = true) {
  if (interactive) {
    save()
    await new Promise(resolve => setTimeout(resolve, 350))
  }
  const values = await chrome.storage.local.get(defaults)
  const button = document.getElementById("test")
  if (interactive) {
    button.disabled = true
    button.textContent = "Testing"
  }
  try {
    const response = await fetch(`http://127.0.0.1:${values.port}/v1/health`)
    if (!response.ok) throw new Error(`Edith returned ${response.status}`)
    await chrome.storage.local.set({ connectionStatus: "connected", lastConnectedAt: new Date().toISOString(), lastError: "" })
    await chrome.runtime.sendMessage({ type: "edith-heartbeat-now" }).catch(() => {})
  } catch (error) {
    await chrome.storage.local.set({ connectionStatus: "offline", lastError: String(error.message || error) })
  }
  if (interactive) {
    button.disabled = false
    button.textContent = "Test connection"
  }
  await renderStatus()
}

async function importHistory() {
  save()
  await new Promise(resolve => setTimeout(resolve, 350))
  const values = await chrome.storage.local.get(defaults)
  const result = document.getElementById("historyResult")
  result.textContent = "Reading this profile"
  try {
    const entries = await chrome.history.search({ text: "", startTime: Date.now() - 30 * 86400000, maxResults: 10000 })
    const visits = entries.filter(item => /^https?:/.test(item.url || "")).map(item => ({
      url: item.url,
      title: item.title || null,
      lastVisitedAt: new Date(item.lastVisitTime).toISOString(),
      visitCount: item.visitCount || 0,
      typedCount: item.typedCount || 0,
      profile: values.profile
    }))
    const response = await fetch(`http://127.0.0.1:${values.port}/v1/history`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Edith-Token": values.token },
      body: JSON.stringify({ profile: values.profile, visits })
    })
    if (!response.ok) throw new Error(`Edith returned ${response.status}`)
    result.textContent = `Imported ${visits.length.toLocaleString()} sites from ${values.profile}. No time was inferred.`
  } catch (error) {
    result.textContent = `Import failed: ${error.message || error}`
  }
}

async function forget() {
  await chrome.storage.local.clear()
  await chrome.storage.session.clear()
  location.reload()
}

document.getElementById("deep").addEventListener("click", toggleDeep)
document.getElementById("test").addEventListener("click", testConnection)
document.getElementById("history").addEventListener("click", importHistory)
document.getElementById("forget").addEventListener("click", forget)
load().then(() => testConnection(false))
setInterval(() => testConnection(false), 5000)
