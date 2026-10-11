export const definition = {
  "schema": 1,
  "owner": "quinjet",
  "activation": {
    "kind": "original-control-callback",
    "control": "Theme",
    "operation": "quinjet.settings.save",
    "sources": [
      {
        "path": "Extensions/quinjet/ViewModels/QuinjetSettingsModel.swift",
        "sha256": "517cc522c82c43cc256bf1b28afedfce785a5390f2afb57a5e1c689ae958cfd3"
      },
      {
        "path": "Extensions/quinjet/Views/QuinjetSettingsPage.swift",
        "sha256": "98dd1bd6f3de0ab2f8ec6b23fc458b78e40ff3122208f193aee9b8dc9762061a"
      }
    ]
  },
  "operations": [
    "quinjet.settings.read",
    "quinjet.settings.save"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "saved app theme preference"
  },
  "persistence": {
    "applicable": true,
    "name": "quinjet terminal and theme preferences"
  },
  "limits": [
    "private-filesystem"
  ]
};
