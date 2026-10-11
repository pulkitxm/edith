export const definition = {
  "schema": 1,
  "owner": "colorPicker",
  "activation": {
    "kind": "original-control-callback",
    "control": "pick",
    "operation": "colorPicker.ui.action",
    "sources": [
      {
        "path": "Extensions/colorPicker/Views/ColorPickerRows.swift",
        "sha256": "183bfbb4ef30970fad19bd8100095c1ca8d5892af23be11903a40f40bfbd540d"
      },
      {
        "path": "Extensions/colorPicker/Presentation.swift",
        "sha256": "29d9bb0935dbe619fb68cbcfc7d98e1f416c5240ad0b706625517fb9d957bdfe"
      },
      {
        "path": "Extensions/colorPicker/Runtime.swift",
        "sha256": "587315e09fba218e8adf8aa8692577a06242cf94d54150c98d5f21055f8de4e6"
      },
      {
        "path": "Extensions/colorPicker/Helper/ViewModels/ColorPickerStore.swift",
        "sha256": "54f7cf717897c8cbee6f4763edbf77d4452127800704e308d68bbe71e2a636b2"
      },
      {
        "path": "Extensions/colorPicker/Models/ColorSwatch.swift",
        "sha256": "8031a900be6ff364a86ce90254532175697c5ee5f38f517c0571f22b5b816262"
      },
      {
        "path": "Extensions/colorPicker/Surface.swift",
        "sha256": "c7455eca73dbbd3ee229234987cb4e7f8e9229c1ebf436ca665bf5701b6db72c"
      }
    ]
  },
  "operations": [
    "colorPicker.ui.read",
    "colorPicker.ui.action",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "colorPicker worker state"
  },
  "persistence": {
    "applicable": true,
    "name": "oldest synthetic swatch"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
