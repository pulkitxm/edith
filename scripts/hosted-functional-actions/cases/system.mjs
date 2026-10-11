export const definition = {
  "schema": 1,
  "owner": "system",
  "activation": {
    "kind": "original-control-callback",
    "control": "App",
    "operation": "system.apps.sort",
    "sources": [
      {
        "path": "Extensions/system/Views/SystemPage.swift",
        "sha256": "76ffc6193be5848e9c8d0fe5e7997109c1df0025b6cdc8101a51de94a95cfe5f"
      },
      {
        "path": "Extensions/system/ViewModels/RunningAppsModel.swift",
        "sha256": "79c357d4d5ad3db88ffcf3fdfda0f0a98169d0c462998f10975102e3838b72e3"
      },
      {
        "path": "Extensions/system/Runtime.swift",
        "sha256": "fc79c5af93448a5ee9fe1f7b0701a72a2d8d432224b79822df0950fa05b19d1b"
      }
    ]
  },
  "operations": [
    "system.apps.snapshot",
    "system.apps.sort"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "systemAppsSort"
  },
  "persistence": {
    "applicable": true,
    "name": "systemAppsSort"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
