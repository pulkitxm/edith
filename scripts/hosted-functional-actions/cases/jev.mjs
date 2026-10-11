export const definition = {
  "schema": 1,
  "owner": "jev",
  "activation": {
    "kind": "original-control-callback",
    "control": "Save",
    "operation": "jev.key.set",
    "sources": [
      {
        "path": "Extensions/jev/Views/JevSettingsPane.swift",
        "sha256": "97bd51e81e8054f52334607d471c5f69eb930ee1af99cbff6d4b29977ad1d361"
      },
      {
        "path": "Extensions/jev/ViewModels/JevSettingsModel.swift",
        "sha256": "59754719108eead642de0288e3c233963c9c84c0ab046a6d4b3ceec4aa47c1e0"
      },
      {
        "path": "Extensions/jev/Services/JevCommands.swift",
        "sha256": "9ba764e61e732b89c18f03900007fea553a1f330c8b03ea039bba6b9dac91b68"
      },
      {
        "path": "Extensions/jev/Services/JevEngine.swift",
        "sha256": "3503267a00874913cec1135e5f6b59eeb1432e75c4937e2ad377d6a0b5575203"
      },
      {
        "path": "Extensions/jev/Services/JevSecrets.swift",
        "sha256": "5f08d4760278f052efb37870b4876cae6109d518c498caf3a0a6321c27c92117"
      },
      {
        "path": "Extensions/jev/Runtime.swift",
        "sha256": "b3ace73b577e89b787143981a9d96f81ae53adb4a9453db144e71ac79b73aed8"
      }
    ]
  },
  "operations": [
    "jev.key.set",
    "jev.status"
  ],
  "observation": {
    "kind": "checked-engine-readback",
    "name": "synthetic key configuration"
  },
  "persistence": {
    "applicable": true,
    "name": "synthetic key configuration"
  },
  "limits": [
    "private-filesystem"
  ]
};
