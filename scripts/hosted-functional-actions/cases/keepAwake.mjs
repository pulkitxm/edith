export const definition = {
  schema: 1,
  owner: "keepAwake",
  activation: {
    kind: "native-accessibility",
    control: "Keep awake",
    operation: "keepAwake.ui.update",
    sources: [
      {
        path: "Extensions/keepAwake/Views/KeepAwakeSettings.swift",
        sha256:
          "501b0d046998c83a0153df6430c74c3e8a8571de26e03a0188b22babc76a0b2a",
      },
    ],
  },
  operations: ["keepAwake.ui.read", "keepAwake.ui.update", "surface.snapshot"],
  observation: {
    kind: "checked-engine-readback",
    name: "owned sleep assertion",
  },
  persistence: {
    applicable: true,
    name: "preventSleep",
  },
  limits: ["synthetic-platform-adapter"],
};
