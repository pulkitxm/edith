export const definition = {
  "schema": 1,
  "owner": "attention",
  "activation": {
    "kind": "original-control-callback",
    "control": "Save tracking settings",
    "operation": "attention.settings.set",
    "sources": [
      {
        "path": "Extensions/attention/NativeRuntime/Sources/AttentionNative/UI/Views/AttentionTrackingSettings.swift",
        "sha256": "5a4d230f6ca81c06708adb21c3b084c09e0182e7fc3a512f065d5ace2af99843"
      }
    ],
    "mutation": {
      "kind": "state-transition",
      "payloadKeys": [
        "enabled",
        "trackingEnabled",
        "browserTrackingEnabled",
        "idleThreshold",
        "privacyLevel",
        "windowTitlesEnabled",
        "iCloudBackupEnabled",
        "serverPort",
        "serverToken",
        "categories",
        "rules",
        "agentTrackingEnabled",
        "mediaTrackingEnabled",
        "jevCategorizationEnabled",
        "focusBlockMinimum",
        "ignoredBundleIDs",
        "profileNote"
      ]
    }
  },
  "operations": [
    "attention.settings.get",
    "attention.settings.set"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "disabled application and browser tracking"
  },
  "persistence": {
    "applicable": true,
    "name": "attention tracking preferences"
  },
  "limits": [
    "synthetic-platform-adapter",
    "private-filesystem"
  ]
};
