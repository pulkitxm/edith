export const definition = {
  schema: 1,
  owner: "blitztree",
  activation: {
    kind: "native-accessibility",
    control: "Move to Trash",
    operation: "blitztree.ui.trash",
    mutation: {
      kind: "state-transition",
      payloadKeys: ["confirmed", "path", "previewToken"],
    },
    sources: [
      {
        path: "Extensions/blitztree/BlitzTreePage.swift",
        sha256:
          "588c87456a19d677b70dc5058bf52bb82368fb15e2d3f0220f64fde2de149620",
      },
      {
        path: "Extensions/blitztree/BlitzTreeModel.swift",
        sha256:
          "1d8bc9d009f638404666d2847b3eb7628d0ad5d8383b06f96fc3e25848b40888",
      },
      {
        path: "Extensions/blitztree/BlitzTreeCommands.swift",
        sha256:
          "3e300c7e465d8f573e9a5acc867685ce304e42f620dfdf339e0e97f4e3cf0150",
      },
      {
        path: "Extensions/blitztree/Runtime.swift",
        sha256:
          "ed638ca20e606fe58b836986ed8ea6e1089d17f017683f43bd114adc10cd02ba",
      },
      {
        path: "Extensions/blitztree/BlitzTreeFixtureFiles.swift",
        sha256:
          "ba061cb6c6af1a6482f9dde77c2f397c71c1c4a94d5ee388b383640417b368ba",
      },
    ],
  },
  operations: [
    "blitztree.ui.scan",
    "blitztree.ui.snapshot",
    "blitztree.ui.trash",
  ],
  observation: {
    kind: "checked-engine-readback",
    name: "scanned synthetic entries",
  },
  persistence: {
    applicable: true,
    name: "owned private trash",
  },
  limits: ["synthetic-platform-adapter"],
};
