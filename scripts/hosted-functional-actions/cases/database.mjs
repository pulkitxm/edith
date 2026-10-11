export const definition = {
  "schema": 1,
  "owner": "database",
  "activation": {
    "kind": "original-control-callback",
    "control": "Column width",
    "operation": "database.ui.columns",
    "sources": [
      {
        "path": "Extensions/database/Models/DatabaseColumnsModel.swift",
        "sha256": "8d4b0d288b2c111e081ff5b8a758783618361b4124abd21adfd63858158c31f5"
      },
      {
        "path": "Extensions/database/DatabaseUIClient.swift",
        "sha256": "eb5b1e22c3a832f18090d84abfda9c7247ba22f29cebd1feaaf5811a39f72c08"
      },
      {
        "path": "Extensions/database/Views/DatabaseNativeTableView.swift",
        "sha256": "12e179e4e5dc9de17d6c711d7f7986c2e5732974e1adec020515c6fffe2fc577"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "data"
      ]
    }
  },
  "operations": [
    "database.ui.state",
    "database.ui.columns"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "saved synthetic table column width"
  },
  "persistence": {
    "applicable": true,
    "name": "database column layout"
  },
  "limits": [
    "private-filesystem"
  ]
};
