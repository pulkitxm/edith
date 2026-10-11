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
      }
    ]
  },
  "operations": [
    "downloads.ui.configuration",
    "downloads.ui.action",
    "download.worker.snapshot"
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
