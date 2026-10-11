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
        "sha256": "366cb274529c87a7625148489ba238ca1c2f9032ceb678343ee15f91b4f42770"
      },
      {
        "path": "Extensions/clipboard/ClipboardPresentation.swift",
        "sha256": "ad654574c5c6c0b176d8038f36601dedb12d3a70ff72b4ee98ed263e0e0cbd21"
      },
      {
        "path": "Extensions/clipboard/ClipboardHistoryModel.swift",
        "sha256": "e4a9337c2a532024a622e52a09fa9763be5913b78f73752a09d21984bc494fe3"
      },
      {
        "path": "Extensions/clipboard/ClipboardClient.swift",
        "sha256": "5005b101feb1e0f83332d0841b117987262a44b3292e76e3cce6b39392e4b545"
      },
      {
        "path": "Extensions/clipboard/Runtime.swift",
        "sha256": "0f69469483a50e1212b26640f1fe8681bb7130ca70ae15de4d62bfdfe0942526"
      },
      {
        "path": "Extensions/clipboard/ClipboardWorker.swift",
        "sha256": "b177befca112578c478f750e46de9199c8002ffc5552b3a170ee7aac0414ba7b"
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
