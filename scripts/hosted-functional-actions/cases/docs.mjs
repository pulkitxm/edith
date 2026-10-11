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
        "sha256": "20b5d7ad46e0d95b517d98798307f2673969aa169a4447dda2287e2d043021b7"
      }
    ]
  },
  "operations": [
    "docs.ui.library",
    "docs.ui.ask"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original action: docs"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "bundled-content"
  ]
};
