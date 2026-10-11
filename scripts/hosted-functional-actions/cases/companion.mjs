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
        "path": "Extensions/companion/Views/CompanionBackendView.swift",
        "sha256": "cb5b2e7b06015da0eccc4cba457caf6998ee044257123709f1011ac7ac928e5d"
      },
      {
        "path": "Extensions/companion/Views/CompanionUI.swift",
        "sha256": "c878c97d2912fa62383f776d08f593e553374fdd77c50adc444eff9f12c8baf9"
      },
      {
        "path": "Extensions/companion/Views/CompanionPage.swift",
        "sha256": "ad4b941a716fb96d92b1c66449b62b5cedd60764b6e121c65b9e1ebedaf1ba88"
      },
      {
        "path": "Extensions/companion/CompanionUIBridge.swift",
        "sha256": "5bfe1a6c26b96df5896efb8c9febd58d9f2109580ba71e69a0b0e1c7af358f12"
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
