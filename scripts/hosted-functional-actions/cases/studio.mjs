export const definition = {
  "schema": 1,
  "owner": "studio",
  "activation": {
    "kind": "original-control-callback",
    "control": "Export",
    "operation": "studio.ui.video.export",
    "sources": [
      {
        "path": "Extensions/studio/VideoEditor/VideoEditorModel.swift",
        "sha256": "06ca5e46d6b1580ec0c669ed69165e95ebe00c26fae4eb37e8b5139fd502db8c"
      },
      {
        "path": "Extensions/studio/UIBridge/StudioUIVideoClient.swift",
        "sha256": "82e64e98cdc7ed086de9707e9c187026b01d7d37404eff89bea4d0d13b0dd6d3"
      },
      {
        "path": "Extensions/studio/Runtime.swift",
        "sha256": "a467a2a771b8b15578bbb442351a73f565bb71d20e0854f69cce914114a449fb"
      }
    ]
  },
  "operations": [
    "studio.ui.video.export",
    "studio.ui.work.read",
    "studio.ui.work.cancel"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original action: studio"
  },
  "persistence": {
    "applicable": true,
    "name": "studio project and completed export"
  },
  "limits": [
    "private-filesystem",
    "owned-toolchain"
  ]
};
