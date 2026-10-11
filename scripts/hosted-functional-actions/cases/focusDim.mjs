export const definition = {
  "schema": 1,
  "owner": "focusDim",
  "activation": {
    "kind": "native-accessibility",
    "control": "Dim now",
    "operation": "focusDim.ui.update",
    "sources": [
      {
        "path": "Extensions/focusDim/Views/FocusDimSettings.swift",
        "sha256": "df5f64f59487d506a6e6a7e9f57c333cc7097b5c3c546af65327ac4d03d6e142"
      },
      {
        "path": "Extensions/focusDim/Presentation.swift",
        "sha256": "3ed7399749328e08e84eb4be07a80ca241182e83a5d6ee08d5598f4072b0ba57"
      },
      {
        "path": "Extensions/focusDim/Runtime.swift",
        "sha256": "8f07e0268ace64cad04331f2dee03d5e397d104b3eae945fd92a0f3f3868b655"
      },
      {
        "path": "Extensions/focusDim/Surface.swift",
        "sha256": "d197d0eb9de75b48f9734c8e90d5df75339edb5763221976ecc8a7cd5fed5ee5"
      }
    ]
  },
  "operations": [
    "focusDim.ui.read",
    "focusDim.ui.update",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "dim"
  },
  "persistence": {
    "applicable": true,
    "name": "focusDimActive"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
