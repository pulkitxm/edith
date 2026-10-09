async function render() {
  const values = await chrome.storage.local.get({ profile: "Default", enabled: true, connectionStatus: "setup", lastConnectedAt: "" })
  document.getElementById("profile").textContent = values.profile
  document.getElementById("enabled").checked = values.enabled
  const status = document.getElementById("popupStatus")
  status.textContent = values.connectionStatus === "connected" ? "Connected to Edith" : values.connectionStatus === "offline" ? "Edith is offline" : "Finish setup"
  status.className = `popup-status ${values.connectionStatus === "connected" ? "good" : "warn"}`
}

document.getElementById("enabled").addEventListener("change", event => chrome.storage.local.set({ enabled: event.target.checked }))
document.getElementById("settings").addEventListener("click", () => chrome.runtime.openOptionsPage())
render()
