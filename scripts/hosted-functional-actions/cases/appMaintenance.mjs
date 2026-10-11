export const definition = {
  "schema": 1,
  "owner": "appMaintenance",
  "activation": {
    "kind": "original-control-callback",
    "control": "Destination",
    "operation": "maintenance.ui.preferences",
    "sources": [
      {
        "path": "Extensions/appMaintenance/AppMaintenanceView.swift",
        "sha256": "0466b71df735698889895e42f6814663bfe36e411d990dc9548fc86fb08600d5"
      },
      {
        "path": "Extensions/appMaintenance/AppMaintenanceModel.swift",
        "sha256": "1de0cffcba577bb0aee3c66790a4ccac1250bc291a29525f39ae3de5177341b5"
      },
      {
        "path": "Extensions/appMaintenance/AppMaintenanceUICommands.swift",
        "sha256": "6e6b05372b5fc8c34b64bd32c169fa284b59779e345f92b4000d4d0bd7497e65"
      },
      {
        "path": "Extensions/appMaintenance/Runtime.swift",
        "sha256": "d25ec4484c71ff8de2de837733efddff5f9ebb8a76b1209d6c35b6b649b6c300"
      }
    ]
  },
  "operations": [
    "maintenance.ui.preferences",
    "maintenance.ui.settings.read",
    "maintenance.ui.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "maintenance.installDestination"
  },
  "persistence": {
    "applicable": true,
    "name": "maintenance.installDestination"
  },
  "limits": [
    "private-filesystem"
  ]
};
