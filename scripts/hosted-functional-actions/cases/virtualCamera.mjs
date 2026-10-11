export const definition = {
  "schema": 1,
  "owner": "virtualCamera",
  "activation": {
    "kind": "original-control-callback",
    "control": "Play",
    "operation": "camera.ui.state",
    "sources": [
      {
        "path": "Extensions/virtualCamera/Views/VirtualCameraPageModel.swift",
        "sha256": "8b78c043c8a996a4b4bd2ca8cc6f1291a3901881ed7f3eab1aff1618271bd7b3"
      },
      {
        "path": "Extensions/virtualCamera/Views/VirtualCameraPage.swift",
        "sha256": "d5ddabc73cf030b6dc7fedb7407758e0cf06a817761b188cd57f2b4a29295430"
      },
      {
        "path": "Extensions/virtualCamera/Runtime.swift",
        "sha256": "e0941a130bb41e6270d0ddb1c7842bae11755712d6074280cb94836c32d9b32a"
      },
      {
        "path": "Extensions/virtualCamera/CameraCarrierRuntime.swift",
        "sha256": "b6c37f4b671b0f0b6c28c25bc10c97764a2b303f1f4d627aef497361417e5295"
      }
    ]
  },
  "operations": [
    "camera.ui.state",
    "camera.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original action: virtualCamera"
  },
  "persistence": {
    "applicable": true,
    "name": "camera scene and output preferences"
  },
  "limits": [
    "synthetic-platform-adapter",
    "privileged-role-unproved"
  ]
};
