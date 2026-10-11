export const definition = {
  "schema": 1,
  "owner": "windowSweaters",
  "activation": {
    "kind": "native-accessibility",
    "control": "Sweaters on",
    "operation": "windowSweaters.ui.update",
    "sources": [
      {
        "path": "Extensions/windowSweaters/Views/WindowSweatersRows.swift",
        "sha256": "656645c83f5cd9eb4480c37453cbe426fca8953869ba11a82c2d7e7e59c7b702"
      },
      {
        "path": "Extensions/windowSweaters/Presentation.swift",
        "sha256": "a37280f12ca4d4fe97052d8239b815c73468fb7b28517de78063011951a8ed2e"
      },
      {
        "path": "Extensions/windowSweaters/Runtime.swift",
        "sha256": "b2475c90e6b508b276529556e42017ae4af602e6be78223fe500ca536fee6b88"
      },
      {
        "path": "Extensions/windowSweaters/Surface.swift",
        "sha256": "04228310d89baa6130f3bf2ab636b9e6b5eb63c004b7b43faa0385c746a8f9d9"
      }
    ]
  },
  "operations": [
    "windowSweaters.ui.read",
    "windowSweaters.ui.update",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "sweaters"
  },
  "persistence": {
    "applicable": true,
    "name": "windowSweatersActive"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
