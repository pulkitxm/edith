export const definition = {
  "schema": 1,
  "owner": "lidAwake",
  "activation": {
    "kind": "original-control-callback",
    "control": "Auto-pause below",
    "operation": "lidAwake.battery",
    "sources": [
      {
        "path": "Extensions/lidAwake/Views/LidAwakeRows.swift",
        "sha256": "89f7d52ff40d1d27583b14dd2f212f7307817a8e99f63b0a0ad13594cf6492ea"
      },
      {
        "path": "Extensions/lidAwake/Views/LidAwakeSettingsModel.swift",
        "sha256": "c90e8b128836cb0736d1908cf9350ee2198d01a197f37b3d862da862f609402f"
      },
      {
        "path": "Extensions/lidAwake/Models/LidAwakeOperations.swift",
        "sha256": "07dd7ab60734a0fe4433b4c22788ba5a7c362e8dcecb3825158c172e597ead9d"
      },
      {
        "path": "Extensions/lidAwake/Services/LidAwakeWorker.swift",
        "sha256": "8387393c33d7b798c3dd0ea4e84f690790bddb611edd4b867601c871d2e56018"
      },
      {
        "path": "Extensions/lidAwake/Surface.swift",
        "sha256": "ba5e11b1dc68843b34b2f2fbaca968ded977cce2aeeda27eb31ce41a7ace7361"
      }
    ]
  },
  "operations": [
    "lidAwake.battery",
    "lidAwake.status"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "lidAwakeBatteryThreshold"
  },
  "persistence": {
    "applicable": true,
    "name": "lidAwakeBatteryThreshold"
  },
  "limits": [
    "synthetic-platform-adapter",
    "privileged-role-unproved"
  ]
};
