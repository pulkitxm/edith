export const definition = {
  "schema": 1,
  "owner": "companion",
  "activation": {
    "kind": "original-control-callback",
    "control": "Save configuration",
    "operation": "companion.ui.backend",
    "sources": [
      {
        "path": "Extensions/companion/ViewModels/CompanionBackendModel.swift",
        "sha256": "f3791ae032a8dd24e9efecf9c98ffce63581553b6fb7ef8dd011053441f472b3"
      },
      {
        "path": "Extensions/companion/Views/CompanionSettingsView.swift",
        "sha256": "ffe6a181e49a9718239f689ce9902c8b78ac0c7f44e292f8e46af77451274508"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "action",
        "config"
      ]
    }
  },
  "operations": [
    "companion.ui.backend"
  ],
  "observation": {
    "kind": "owned-file-output",
    "name": "saved synthetic stack configuration"
  },
  "persistence": {
    "applicable": true,
    "name": "companion stack configuration"
  },
  "limits": [
    "private-filesystem"
  ]
};
