export const definition = {
  "schema": 1,
  "owner": "keystrokeHighlight",
  "activation": {
    "kind": "native-accessibility",
    "control": "Show keystrokes",
    "operation": "keystrokeHighlight.ui.update",
    "sources": [
      {
        "path": "Extensions/keystrokeHighlight/Views/KeystrokeHighlightRows.swift",
        "sha256": "4ad803d9819ed04f1d3dba2bc5d5d98c048dfae60c3c9891e9d501bab48c05d8"
      },
      {
        "path": "Extensions/keystrokeHighlight/Presentation.swift",
        "sha256": "864050c5b09d2b1558e5bc150641418dcd768dfab38cf2cf759e32f2b399f958"
      },
      {
        "path": "Extensions/keystrokeHighlight/Runtime.swift",
        "sha256": "57af7074beb80ab779bbd09994531acf982eabaa6fb2399a085ba0686ee87142"
      },
      {
        "path": "Extensions/keystrokeHighlight/Surface.swift",
        "sha256": "7f1795282d7baa651209174ecc5273b33870625fb4ffbe40c23deba13f6f52e5"
      }
    ]
  },
  "operations": [
    "keystrokeHighlight.ui.read",
    "keystrokeHighlight.ui.update",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "keys"
  },
  "persistence": {
    "applicable": true,
    "name": "keystrokeHighlightActive"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
