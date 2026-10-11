export const definition = {
  "schema": 1,
  "owner": "timeLapse",
  "activation": {
    "kind": "original-control-callback",
    "control": "Start recording",
    "operation": "recording.ui.start",
    "sources": [
      {
        "path": "Extensions/timeLapse/TimeLapsePage.swift",
        "sha256": "8a85de0e196027fb8c94cb6fae39e8cb2da688966518a5a84c33d47723c669cc"
      },
      {
        "path": "Extensions/timeLapse/TimeLapseRecorder.swift",
        "sha256": "af675d5c8d19d4d0031827e67766402d0ac95d13591cdb397b156ddf7a3dde13"
      },
      {
        "path": "Extensions/timeLapse/TimeLapseUICommands.swift",
        "sha256": "21fb0ea86e27439898a0c30b0fcdcb6b4c0d2f5bd8586a8f6aaac0a332d489d3"
      },
      {
        "path": "Extensions/timeLapse/Runtime.swift",
        "sha256": "168a74137e1effdf56eb69c6511b4f034ffcd28550fa4bb9745cd2645039c7dc"
      }
    ]
  },
  "operations": [
    "recording.ui.start",
    "recording.ui.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original control"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
