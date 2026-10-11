export const definition = {
  "schema": 1,
  "owner": "music",
  "activation": {
    "kind": "original-control-callback",
    "control": "Collapsed sidebar player",
    "operation": "music.ui.action",
    "sources": [
      {
        "path": "Extensions/music/UI/MusicSettings.swift",
        "sha256": "cc00096eb6c435699ad3547129770362c056cb02b9c145c23df3c9fcdc7c8408"
      },
      {
        "path": "Extensions/music/UI/MusicSettingsModel.swift",
        "sha256": "8ed939545716c39c2128cf68c5cef6a88c155229ca47463552deef55b5be25fc"
      },
      {
        "path": "Extensions/music/Runtime.swift",
        "sha256": "43c40e804a7a59338245af05a8d48bd3213421693f22e8d49587f3276b184fd5"
      },
      {
        "path": "Extensions/music/UI/MusicUIEnvelope.swift",
        "sha256": "92410906abb2e3dbd35ebe43276b484adf7fa4bd8eb8f5e17e7f3cb61a68041d"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "kind",
        "path",
        "target",
        "value"
      ]
    }
  },
  "operations": [
    "music.ui.settings",
    "music.ui.action"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original action: music"
  },
  "persistence": {
    "applicable": true,
    "name": "music sidecar history and preferences"
  },
  "limits": [
    "private-filesystem"
  ]
};
