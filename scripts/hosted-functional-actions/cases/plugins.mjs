export const definition = {
  "schema": 1,
  "owner": "plugins",
  "activation": {
    "kind": "original-control-callback",
    "control": "Install plugin",
    "operation": "plugins.ui.action",
    "sources": [
      {
        "path": "Extensions/plugins/SkillsModel.swift",
        "sha256": "6727790ebef953ebc80a6159a7e9fc48e53a51cd574aa97abda1f850e058de6a"
      },
      {
        "path": "Extensions/plugins/PluginsUIBridge.swift",
        "sha256": "9944828ece81820da4052b113169e80a142bec89b26464908f87cefca0a833c1"
      },
      {
        "path": "Extensions/plugins/Runtime.swift",
        "sha256": "c44cb44d1dc8429f13f47e9c3f87d01cefb79ae68dc2a464d9de02113f39a9fe"
      }
    ]
  },
  "operations": [
    "plugins.ui.action",
    "surface.snapshot"
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
    "owned-toolchain",
    "private-filesystem"
  ]
};
