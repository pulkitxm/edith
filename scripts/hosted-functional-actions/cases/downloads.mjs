export const definition = {
  "schema": 1,
  "owner": "downloads",
  "activation": {
    "kind": "original-control-callback",
    "control": "Default format",
    "operation": "downloads.ui.action",
    "sources": [
      {
        "path": "Extensions/downloads/Views/DownloadsSettings.swift",
        "sha256": "81dffdd521f5a0c269783fe0c134e1d3382fae77fc6511c5ef791e272381e018"
      },
      {
        "path": "Extensions/downloads/Services/YoutubeDownloader.swift",
        "sha256": "3eba1c3bfc891a3ca488d7892d55f2bb21fe97e20752ec69505e0a0eac7e1fc2"
      },
      {
        "path": "Extensions/downloads/Worker.swift",
        "sha256": "fdd625cfed1f3d6b32566c29a28c6ef40b9ffad2965aa0c12bfc356b1c612d57"
      },
      {
        "path": "Extensions/downloads/Services/DownloadsClient.swift",
        "sha256": "47ce73c31e2db08a784b8e8f00086ab81270717d70d74d8260a505a353c585df"
      },
      {
        "path": "Extensions/downloads/Models/DownloadQueue.swift",
        "sha256": "58c18bb891afbad0d2872244a86a569a22621b11d111d9c08eb1265cf4f9005d"
      }
    ]
  },
  "operations": [
    "downloads.ui.configuration",
    "downloads.ui.action",
    "downloads.snapshot"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "preferred format and retained download records"
  },
  "persistence": {
    "applicable": true,
    "name": "download history and audio folder preferences"
  },
  "limits": [
    "private-filesystem"
  ]
};
