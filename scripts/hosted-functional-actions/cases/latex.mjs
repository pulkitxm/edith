export const definition = {
  "schema": 1,
  "owner": "latex",
  "activation": {
    "kind": "original-control-callback",
    "control": "Source editor",
    "operation": "latex.ui.action",
    "sources": [
      {
        "path": "Extensions/latex/LaTeXModel.swift",
        "sha256": "5c1933aff553b84150e7499e7c474da7e72a603ac501e8686573c6e71a925155"
      },
      {
        "path": "Extensions/latex/LaTeXPage.swift",
        "sha256": "d8c1b580c4adfcafa22808dda53b3187ce3cca778be77f37eba0407352caf997"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "action",
        "projectID",
        "revision",
        "text"
      ]
    }
  },
  "operations": [
    "latex.ui.snapshot",
    "latex.ui.action"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "retained source editor draft"
  },
  "persistence": {
    "applicable": true,
    "name": "latex source draft"
  },
  "limits": [
    "private-filesystem"
  ]
};
