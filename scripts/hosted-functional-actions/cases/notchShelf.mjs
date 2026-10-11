export const definition = {
  "schema": 1,
  "owner": "notchShelf",
  "activation": {
    "kind": "original-control-callback",
    "control": "Require ⌥ to trigger",
    "operation": "notch.settings.write",
    "sources": [
      {
        "path": "Extensions/notchShelf/Shelf/Views/NotchSettingsPage.swift",
        "sha256": "d1c33a16ce42c2d037ad6d4f53ec9a4e57e5a26729164ce6d65c0dcaa1d81268"
      },
      {
        "path": "Extensions/notchShelf/Settings/NotchSettingsModel.swift",
        "sha256": "7c6c4b763e503a7ca3f5c3576d2ac9b232c1f2aec59bbc6eb232b84e93ca6ecb"
      },
      {
        "path": "Extensions/notchShelf/Settings/NotchSettingsOperations.swift",
        "sha256": "0969f43bc2d77e498c441aed8c54e13c6500bc0c1d5942e3e9d69529636ab3cc"
      },
      {
        "path": "Extensions/notchShelf/Runtime.swift",
        "sha256": "d902150691582ba80e0298177987aa5d19de113e366ab5f3b20384571aef188b"
      }
    ]
  },
  "operations": [
    "notch.settings.read",
    "notch.settings.write"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "blocked original control"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
