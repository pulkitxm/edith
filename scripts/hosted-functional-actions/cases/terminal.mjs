export const definition = {
  "schema": 1,
  "owner": "terminal",
  "activation": {
    "kind": "original-control-callback",
    "control": "Show and New terminal",
    "operation": "terminal.open",
    "sources": [
      {
        "path": "Extensions/terminal/TerminalPage.swift",
        "sha256": "b69d527708229f34fc0c0b89c4980f16e9d417970c8455a40bcd2c8b41937d4e"
      },
      {
        "path": "Extensions/terminal/TerminalTabsView.swift",
        "sha256": "a0f24fda3abf711beb4806027967e01c10e9d95db2e3590191061159293de4d3"
      },
      {
        "path": "Extensions/terminal/TerminalTabsModel.swift",
        "sha256": "8cd38f5eb74fbf579a66e86256578f7a4455abac123b8395da9df5f2161ae168"
      },
      {
        "path": "Extensions/terminal/Native/Package.swift",
        "sha256": "7afd4a4d699e8c8a18ba088f053132b5cdc1a58be9aa5c03a45c870cc2c9f6fc"
      }
    ],
    "mutation": {
      "kind": "owned-output",
      "payloadKeys": []
    }
  },
  "operations": [
    "terminal.preferences",
    "terminal.snapshot",
    "terminal.open",
    "terminal.input",
    "terminal.read",
    "terminal.closeAll"
  ],
  "observation": {
    "kind": "owned-process-output",
    "name": "owned shell output from original Show and New delivery"
  },
  "persistence": {
    "applicable": true,
    "name": "terminal preferences"
  },
  "limits": [
    "owned-pty",
    "private-filesystem"
  ]
};
