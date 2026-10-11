export const definition = {
  "schema": 1,
  "owner": "micMute",
  "activation": {
    "kind": "original-control-callback",
    "control": "Mute microphones",
    "operation": "micMute.ui.action",
    "sources": [
      {
        "path": "Extensions/micMute/Views/MicMuteRows.swift",
        "sha256": "9366f32af4860c6206d825598dd8a1ba98315c811bd2dcf758171516a5fa19d9"
      },
      {
        "path": "Extensions/micMute/Presentation.swift",
        "sha256": "caa997b5e007e256cd2f7e317f146fa3bacba91bb88cb3e58bfbf6792c44e899"
      },
      {
        "path": "Extensions/micMute/Runtime.swift",
        "sha256": "d920701566afdf6eb8aa928b6be4543f08442efdac74819b3c0987259ce8c762"
      },
      {
        "path": "Extensions/micMute/Helper/Services/MicMuteEngine.swift",
        "sha256": "88acf7b9048f80a1c8b1b747bd94084bd00ee6a91a5f4e34689999976e04efb1"
      },
      {
        "path": "Extensions/micMute/Surface.swift",
        "sha256": "275f3340ee3f71c1c006f7fc9761cd57a3c5f9f8d727a705c82f808f04e9be88"
      }
    ]
  },
  "operations": [
    "micMute.ui.read",
    "micMute.ui.action",
    "surface.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "micMute worker state"
  },
  "persistence": {
    "applicable": true,
    "name": "micMuted"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
