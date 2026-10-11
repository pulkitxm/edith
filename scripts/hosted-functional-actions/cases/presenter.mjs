export const definition = {
  "schema": 1,
  "owner": "presenter",
  "activation": {
    "kind": "native-accessibility",
    "control": "Manual presenter mode",
    "operation": "presenter.ui.update",
    "sources": [
      {
        "path": "Extensions/presenter/Views/PresenterRows.swift",
        "sha256": "d0dcdd8f9fc120a7703538688265cc95733228b152b5157385107a5d526a0add"
      },
      {
        "path": "Extensions/presenter/Presentation.swift",
        "sha256": "1fad15508b62b77953092c0a2f357612fd16381aa6d9673efc72efa56b1bfb67"
      },
      {
        "path": "Extensions/presenter/Runtime.swift",
        "sha256": "9236b3353c0e027b4a6a5bd72f0f7baebe2bbb492bb3a25a68ed67e16e5ff09d"
      },
      {
        "path": "Extensions/presenter/Surface.swift",
        "sha256": "3386b128297a39dfc9980bc50643071618ad0c7e78969da830f73742cc8f98b7"
      }
    ]
  },
  "operations": [
    "presenter.ui.read",
    "presenter.ui.update",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "presenter"
  },
  "persistence": {
    "applicable": true,
    "name": "presenterMode"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
