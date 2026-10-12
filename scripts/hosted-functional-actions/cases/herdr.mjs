export const definition = {
  "schema": 1,
  "owner": "herdr",
  "activation": {
    "kind": "original-control-callback",
    "control": "Stuck threshold",
    "operation": "herdr.settings.save",
    "sources": [
      {
        "path": "Extensions/herdr/ViewModels/HerdrSettingsModel.swift",
        "sha256": "7c2ad191f18810cac7544d9633130467104643563633b799cb45b8892078f53c"
      },
      {
        "path": "Extensions/herdr/Views/HerdrSettingsPage.swift",
        "sha256": "5e0c325da5a7f7cf0ba37c02cf3b9c1e06c5269d4c6d75af4a6c84ad8efce237"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "blocked",
        "finished",
        "errors",
        "stuck",
        "openDiff",
        "monitoring",
        "stuckMinutes"
      ]
    }
  },
  "operations": [
    "herdr.settings.read",
    "herdr.settings.save"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "saved synthetic attention threshold"
  },
  "persistence": {
    "applicable": true,
    "name": "herdr attention preferences"
  },
  "limits": [
    "private-filesystem"
  ]
};
