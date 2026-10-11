export const definition = {
  "schema": 1,
  "owner": "docs",
  "activation": {
    "kind": "original-control-callback",
    "control": "Ask",
    "operation": "docs.ui.ask",
    "sources": [
      {
        "path": "Extensions/docs/DocsBrowser.swift",
        "sha256": "e1d8f53c54e614efd597be055993fee7519971b74a18cbcb9df218920fb2d34d"
      },
      {
        "path": "Extensions/docs/DocsUIBridge.swift",
        "sha256": "fff656e44e64b932aa1d6a6b6751c43d0a85c2c3cc63d5150d75388cd904ba08"
      },
      {
        "path": "Extensions/docs/DocsScreen.swift",
        "sha256": "afaea6b5a2d3a4fed6238e175d92756321cdbafed29c9c693d06740900835f24"
      }
    ],
    "mutation": {
      "kind": "owned-output",
      "payloadKeys": [
        "request"
      ]
    }
  },
  "operations": [
    "docs.ui.library",
    "docs.ui.ask"
  ],
  "observation": {
    "kind": "owned-process-output",
    "name": "blocked original Ask rendered result observer"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "bundled-content"
  ]
};
