export const definition = {
  "schema": 1,
  "owner": "emoji",
  "activation": {
    "kind": "original-control-callback",
    "control": "clear",
    "operation": "emoji.ui.action",
    "sources": [
      {
        "path": "Extensions/emoji/Views/EmojiSettingsRows.swift",
        "sha256": "fb9c9d07e52315ff5c024c95855ebedfa8addef7576b4d0e375daeff2f7b01d9"
      },
      {
        "path": "Extensions/emoji/Presentation.swift",
        "sha256": "ea1d156d1cb464b692d278dead363b25c3cb34deea19e6d28a250d7bb8f16986"
      },
      {
        "path": "Extensions/emoji/Runtime.swift",
        "sha256": "edb5ef8141b703af5431a9e0d91212a4cf0f05de553f42bc0d43a658d201ca1b"
      },
      {
        "path": "Extensions/emoji/EdithHelper/ViewModels/EmojiStore.swift",
        "sha256": "3a542f0350bdb68615a4dc4553210fe09c5f7e76f415929e830625c2dd873828"
      },
      {
        "path": "Extensions/emoji/EdithKit/Services/EmojiUsageLedger.swift",
        "sha256": "aa78085f81392266b61aa954e6f7d0423f9ccc8525162840c7c4d836def59393"
      },
      {
        "path": "Extensions/emoji/Surface.swift",
        "sha256": "9f0613f9f753d0c554b5d88abb409fcf5ea0b3574da1e7ee79d64725692a2345"
      }
    ]
  },
  "operations": [
    "emoji.ui.read",
    "emoji.ui.action",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "emoji worker state"
  },
  "persistence": {
    "applicable": true,
    "name": "empty emojiUsage ledger"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
