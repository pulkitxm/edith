export const definition = {
  "schema": 1,
  "owner": "clipboard",
  "activation": {
    "kind": "original-control-callback",
    "control": "Pin",
    "operation": "clipboard.ui.mutate",
    "sources": [
      {
        "path": "Extensions/clipboard/ClipboardPage.swift",
        "sha256": "531daf9d5e1eab3ea7c89834eb95a3984415a38d9bb401d2f47c5ae7ae3c0708"
      },
      {
        "path": "Extensions/clipboard/ClipboardRows.swift",
        "sha256": "24e10339e08b85407d70c6051fcde7cbfdd051341136f4dc518b4a981232b3f8"
      },
      {
        "path": "Extensions/clipboard/ClipboardHistoryView.swift",
        "sha256": "e6a0985cdadfb9811d268ef96d7e08552b3b0e9356e4a628a8b8b06c7c6e7aef"
      },
      {
        "path": "Extensions/clipboard/ClipboardPresentation.swift",
        "sha256": "cd8b366315ababd086d8c76f1b1e612e29af946934378bc364d22b5dac31e06e"
      },
      {
        "path": "Extensions/clipboard/ClipboardHistoryModel.swift",
        "sha256": "e7df786895da51dac45228e06c92568579caa549117fbf04a84f145d86ab2e2b"
      },
      {
        "path": "Extensions/clipboard/ClipboardClient.swift",
        "sha256": "5005b101feb1e0f83332d0841b117987262a44b3292e76e3cce6b39392e4b545"
      },
      {
        "path": "Extensions/clipboard/Runtime.swift",
        "sha256": "409e052b2478664e6644afb0ecc6fa8ab444d27e99d0e5f0035451b286c1e109"
      },
      {
        "path": "Extensions/clipboard/ClipboardWorker.swift",
        "sha256": "96d9178d99be9559fb87fa04b8144b3f255b8460ea28e4879d1b43ab5abd47c5"
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
    "clipboard.ui.preferences",
    "clipboard.ui.snapshot",
    "clipboard.ui.mutate"
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
