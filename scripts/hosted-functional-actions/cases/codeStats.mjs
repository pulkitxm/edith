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
      },
      {
        "path": "Extensions/codeStats/CodeStatsUIBridge.swift",
        "sha256": "6b62c5707fbeea46cd0850349459eb93d804d54724d2a0b2a71f1a8f077f1d59"
      },
      {
        "path": "Extensions/codeStats/Runtime.swift",
        "sha256": "25cfa25d56ba41c3343871b2530ed9c4e80c3bef2f7bc056ce8517cb7164a8e9"
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
