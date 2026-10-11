export const definition = {
  "schema": 1,
  "owner": "cleaner",
  "activation": {
    "kind": "original-control-callback",
    "control": "Add folder…",
    "operation": "cleaner.ui.action",
    "sources": [
      {
        "path": "Extensions/cleaner/CleanerViews.swift",
        "sha256": "98adebe05d4d9597fe5dcf05bb4f6a65fbc060df6f5045c57355b8e36d438b27"
      },
      {
        "path": "Extensions/cleaner/CleanerModel.swift",
        "sha256": "d9b0e1d46fadd2dd158fe9dffbba09cbc5a7ab50b1c301a549fbee43f7186456"
      },
      {
        "path": "Extensions/cleaner/CleanerUICommands.swift",
        "sha256": "c8af20161c10d71f7f7d009023fd3aa15c72ea82196e76fb9bbe91bd71a96e29"
      },
      {
        "path": "Extensions/cleaner/Runtime.swift",
        "sha256": "afb9adbb30c85f1924c857f2cc70c8ea087f7ae9ac01df5d420f9524b0ad02f3"
      }
    ]
  },
  "operations": [
    "cleaner.ui.action",
    "cleaner.ui.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "cleaner.customFolders"
  },
  "persistence": {
    "applicable": true,
    "name": "cleaner.customFolders"
  },
  "limits": [
    "private-filesystem"
  ]
};
