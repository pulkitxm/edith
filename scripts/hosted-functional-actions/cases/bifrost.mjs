export const definition = {
  "schema": 1,
  "owner": "bifrost",
  "activation": {
    "kind": "original-control-callback",
    "control": "Paste snippets into the app you were typing in",
    "operation": "bifrost.ui.set",
    "sources": [
      {
        "path": "Extensions/bifrost/Views/BifrostRows.swift",
        "sha256": "d91b178cec59faf4e5743f5072b5fd89a9b5d8d65ef837285364b8afe3e507a2"
      },
      {
        "path": "Extensions/bifrost/BifrostUIContext.swift",
        "sha256": "73f7c8c6ad21d4987a6d44dc5afe88abf45579f8aa72a9a5cb7a3ca206a84917"
      },
      {
        "path": "Extensions/bifrost/Services/BifrostWorker.swift",
        "sha256": "c7cbc7d6ee891d2003a6e2290685b513f799d3b3235ab5b052908b18644a133f"
      },
      {
        "path": "Extensions/bifrost/Services/BifrostFixture.swift",
        "sha256": "f5dba6c51fc6b7c581cc8fe6339cc544c1500c8823fd6cbe27804972ebeb06a1"
      },
      {
        "path": "Extensions/bifrost/Runtime.swift",
        "sha256": "51bfa3fe323d9da4551657c8b019008545ad6ffae3df5448fd4a7902de0f17c6"
      }
    ]
  },
  "operations": [
    "bifrost.ui.settings",
    "bifrost.ui.set"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "bifrostPasteSnippets"
  },
  "persistence": {
    "applicable": true,
    "name": "bifrostPasteSnippets"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
