export const definition = {
  "schema": 1,
  "owner": "usage",
  "activation": {
    "kind": "native-accessibility",
    "control": "Budget pacing toggle",
    "operation": "usage.ui.preferences.set",
    "sources": [
      {
        "path": "Extensions/usage/Views/UsageSettingsRows.swift",
        "sha256": "0da8d31dc80397c9be52fdea42fff44b07102af88adc3f255888359228053ee8"
      },
      {
        "path": "Extensions/usage/ViewModels/UsageUIClient.swift",
        "sha256": "00e6d65a36e3610c5a4f7b9b94d7458b32e9255df07620dc8672919f9c8c1720"
      }
    ]
  },
  "operations": [
    "usage.ui.preferences",
    "usage.ui.preferences.set",
    "usage.statusline.status"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "budget pacing preference in the seeded private fixture"
  },
  "persistence": {
    "applicable": true,
    "name": "usage budget preferences"
  },
  "limits": [
    "private-filesystem"
  ]
};
