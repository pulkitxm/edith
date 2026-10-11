export const definition = {
  "schema": 1,
  "owner": "clipboard",
  "activation": {
    "kind": "original-control-callback",
    "control": "Pin",
    "operation": "clipboard.mutate",
    "sources": [
      {
        "path": "Extensions/clipboard/ClipboardHistoryModel.swift",
        "sha256": "e4a9337c2a532024a622e52a09fa9763be5913b78f73752a09d21984bc494fe3"
      },
      {
        "path": "Extensions/clipboard/ClipboardPage.swift",
        "sha256": "531daf9d5e1eab3ea7c89834eb95a3984415a38d9bb401d2f47c5ae7ae3c0708"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "kind",
        "ids",
        "copiedAt"
      ]
    }
  },
  "operations": [
    "clipboard.snapshot",
    "clipboard.mutate"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "pinned synthetic clipboard record"
  },
  "persistence": {
    "applicable": true,
    "name": "clipboard pin and payload digest"
  },
  "limits": [
    "private-filesystem"
  ]
};
