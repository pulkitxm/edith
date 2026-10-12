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
        "sha256": "b7e5de2d7f44bed1d061df0558cc1bd599af732b2b4093cde6b0523f149e05c4"
      },
      {
        "path": "Extensions/codeStats/Views/CodeStatsPage.swift",
        "sha256": "4c9afc790726f99c8a983e64e95f709125aca5a4c9d7e324b9ccc9fffa7e61f6"
      },
      {
        "path": "Extensions/codeStats/Services/CodeStatsWorkflow.swift",
        "sha256": "290154ff354204ee6aa2dd4c72a8f77da4929b1ff0de63ecd1c15f4eeb87ca14"
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
    "codeStats.ui.status",
    "codeStats.ui.facts",
    "codeStats.ui.report",
    "codeStats.ui.profile"
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
