export const definition = {
  "schema": 1,
  "owner": "audioMixer",
  "activation": {
    "kind": "original-control-callback",
    "control": "Volume slider",
    "operation": "audioMixer.request",
    "sources": [
      {
        "path": "Extensions/audioMixer/AudioMixerRemoteModel.swift",
        "sha256": "cd0212fc1d45e74f42a2d3cfc0683eb2e67b7fdc6a1fa6574d2a51ae471a432d"
      },
      {
        "path": "Extensions/audioMixer/Views/AudioMixerView.swift",
        "sha256": "38faf31c950adb0f4d5f9846a68221288a8d542a0daa2d49f54d674a2938af55"
      }
    ]
  },
  "operations": [
    "audioMixer.ui.snapshot",
    "audioMixer.request"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "synthetic mixer gain"
  },
  "persistence": {
    "applicable": false,
    "name": "no-owned-persistent-record"
  },
  "limits": [
    "synthetic-platform-adapter"
  ]
};
