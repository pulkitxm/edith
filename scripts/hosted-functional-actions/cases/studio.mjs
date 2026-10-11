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
      },
      {
        "path": "Extensions/studio/UIBridge/StudioUILongOperations.swift",
        "sha256": "daba3765d97c47ed982714dc5ce60f72f0c2c6ab1d03f5112a94afeef6b64990"
      },
      {
        "path": "Extensions/studio/UIBridge/StudioUIVideoSessions.swift",
        "sha256": "a911dfe8ee9fe4a7a12c316570e2642c4bf3667d387be39b1af92d670ef2cd21"
      }
    ],
    "mutation": {
      "kind": "owned-output",
      "payloadKeys": [
        "id",
        "format",
        "output",
        "settings",
        "quality",
        "fps",
        "width",
        "loop",
        "workToken"
      ]
    }
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
