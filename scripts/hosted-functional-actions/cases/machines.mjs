export const definition = {
  "schema": 1,
  "owner": "machines",
  "activation": {
    "kind": "original-control-callback",
    "control": "Save machine",
    "operation": "machines.ui.mutate",
    "sources": [
      {
        "path": "Extensions/machines/UI/ViewModels/MachinesModel.swift",
        "sha256": "81db5a5d3354ba290bcadd577966179a1e0c9a42a86cebfb0aab72a5e7d402ae"
      },
      {
        "path": "Extensions/machines/UI/Views/AddMachineSheet.swift",
        "sha256": "c1a5fa458787693ecd01391fcada5d4d6b7e980e3a460061d17c2e18f2606736"
      }
    ]
  },
  "operations": [
    "machines.ui.state",
    "machines.ui.mutate"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "renamed synthetic machine record"
  },
  "persistence": {
    "applicable": true,
    "name": "private machine registry"
  },
  "limits": [
    "private-filesystem"
  ]
};
