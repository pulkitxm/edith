export const definition = {
  "schema": 1,
  "owner": "blitztree",
  "activation": {
    "kind": "original-control-callback",
    "control": "Move to Trash",
    "operation": "blitztree.ui.trash",
    "sources": [
      {
        "path": "Extensions/blitztree/BlitzTreePage.swift",
        "sha256": "588c87456a19d677b70dc5058bf52bb82368fb15e2d3f0220f64fde2de149620"
      },
      {
        "path": "Extensions/blitztree/BlitzTreeModel.swift",
        "sha256": "031fef0a7426a9c8e14af7dde854a2ae3ee8fc788626a81c5471cf0dd22c552d"
      },
      {
        "path": "Extensions/blitztree/BlitzTreeCommands.swift",
        "sha256": "67e2c59975dc48be0305bda5b4549f09cf2ef9baf2710531fe0bf3ac97dcefb7"
      },
      {
        "path": "Extensions/blitztree/BlitzTreeActions.swift",
        "sha256": "12d310b3d6f695069977237d727cfedd0c8c50c629a8b5531778a21934438680"
      },
      {
        "path": "Extensions/blitztree/Runtime.swift",
        "sha256": "00ca9d2d9bf7090e9ff11e24271688396ab37f9920989b44dc800edb6bdd7b30"
      }
    ]
  },
  "operations": [
    "blitztree.ui.scan",
    "blitztree.ui.snapshot",
    "blitztree.ui.trash"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original control"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "private-filesystem",
    "owned-toolchain"
  ]
};
