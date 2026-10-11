export const definition = {
  "schema": 1,
  "owner": "systemStats",
  "activation": {
    "kind": "original-control-callback",
    "control": "Color",
    "operation": "systemStats.ui.update",
    "sources": [
      {
        "path": "Extensions/systemStats/Settings.swift",
        "sha256": "96b4d5cd760dab92fcef106514fedf7bc1f063840bb5794ad8226c106c78a922"
      },
      {
        "path": "Extensions/systemStats/Presentation.swift",
        "sha256": "121182b9795b26df378ce6ceec3b32129a0b37c7ea0f6c63f903392db46daaa1"
      },
      {
        "path": "Extensions/systemStats/Runtime.swift",
        "sha256": "7659768886bc0e62657ab1bad9969078430b86b5777a5a95dcda200742abe66d"
      }
    ]
  },
  "operations": [
    "systemStats.ui.read",
    "systemStats.ui.update"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "menuBarStatsColorMode"
  },
  "persistence": {
    "applicable": true,
    "name": "menuBarStatsColorMode"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
