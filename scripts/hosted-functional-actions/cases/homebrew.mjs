export const definition = {
  "schema": 1,
  "owner": "homebrew",
  "activation": {
    "kind": "original-control-callback",
    "control": "Package kind",
    "operation": "homebrew.preference.write",
    "sources": [
      {
        "path": "Extensions/homebrew/Views/HomebrewPage.swift",
        "sha256": "d8d2f13bd939bf08139a2a46339f326c3e351a65090cd2fc4e61c0059b75c117"
      },
      {
        "path": "Extensions/homebrew/ViewModels/HomebrewPageModel.swift",
        "sha256": "be02ffa9e123f968060fdeeead80e711c514437aba00d953e6f8226b961119f4"
      },
      {
        "path": "Extensions/homebrew/HomebrewPageClient.swift",
        "sha256": "a7b05c98a8d8a8d6559c9ce0e0fd9752d61abf76ef33c9bb30b7823c16d77b97"
      },
      {
        "path": "Extensions/homebrew/HomebrewEngineCommands.swift",
        "sha256": "a56ae3dd446de2f9cfc3bf612b01ce6c8a790f67826e5100d5efcddb4598235f"
      },
      {
        "path": "Extensions/homebrew/Runtime.swift",
        "sha256": "c4344710ed0344f687a8e7a02f0f4a63e8bb1120789be9df081d8f58ee71e339"
      }
    ]
  },
  "operations": [
    "homebrew.preference.read",
    "homebrew.preference.write"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "homebrewDefaultKind"
  },
  "persistence": {
    "applicable": true,
    "name": "homebrewDefaultKind"
  },
  "limits": [
    "private-filesystem"
  ]
};
