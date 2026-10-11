export const definition = {
  "schema": 1,
  "owner": "codeStats",
  "activation": {
    "kind": "original-control-callback",
    "control": "Choose folder",
    "operation": "codeStats.ui.folder",
    "sources": [
      {
        "path": "Extensions/codeStats/ViewModels/CodeStatsModel.swift",
        "sha256": "537c4e0e647c44464503b2c3c549150f3f5280ddb41cd5443c2ded70458207cf"
      },
      {
        "path": "Extensions/codeStats/Views/CodeStatsSetupView.swift",
        "sha256": "f2df959cff9b1f76017530d9e54a629aa781f0037bf9936b4abbb71fb9d184b9"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "folder"
      ]
    }
  },
  "operations": [
    "codeStats.ui.folder",
    "codeStats.ui.status"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "selected synthetic repository folder"
  },
  "persistence": {
    "applicable": true,
    "name": "code statistics folder preference"
  },
  "limits": [
    "private-filesystem"
  ]
};
