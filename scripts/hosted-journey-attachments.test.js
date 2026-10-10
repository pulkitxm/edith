import { expect, test } from "bun:test";
import { mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  attachmentCommandFailureCategory,
  observeAttachmentToolVersion,
  validateAttachmentToolSchema,
} from "./hosted-original-shell/attachment-tool.mjs";
import {
  attachmentExportArguments,
  exportJourneyAttachments,
  journeyTestIdentifier,
  readJourneyAttachments,
  selectJourneyAttachments,
} from "./hosted-original-shell/attachments.mjs";

function attachment(name, file = `${name}.export`) {
  return { suggestedHumanReadableName: name, exportedFileName: file };
}
function manifest(attachments) {
  return [{ testIdentifier: journeyTestIdentifier, attachments }];
}
const first = attachment("edith-journey-outcome-0001.json");

const toolVersion =
  "xcresulttool version 23000, schema version: 0.3.0 (legacy commands format version: 3.50)\n";
const toolSchema = JSON.stringify({
  schemas: {
    AttachmentDetails: {
      type: "array",
      items: { $ref: "#/schemas/TestAttachmentDetails" },
    },
    TestAttachmentDetails: {
      type: "object",
      properties: {
        testIdentifier: { type: "string" },
        attachments: { type: "array", items: { $ref: "#/schemas/Attachment" } },
      },
      required: ["testIdentifier", "attachments"],
    },
    Attachment: {
      type: "object",
      properties: {
        exportedFileName: { type: "string" },
        suggestedHumanReadableName: { type: "string" },
      },
      required: ["exportedFileName", "suggestedHumanReadableName"],
    },
  },
});

test("official exporter uses the supported default and exact owned test without a filename filter", () => {
  const args = attachmentExportArguments(
    "/fixture/HostedShellJourney.xcresult",
    "/fixture/journey-attachments",
  );
  expect(args).toEqual([
    "xcresulttool",
    "export",
    "attachments",
    "--test-id",
    journeyTestIdentifier,
    "--path",
    "/fixture/HostedShellJourney.xcresult",
    "--output-path",
    "/fixture/journey-attachments",
  ]);
  for (const paths of [
    ["relative.xcresult", "/fixture/journey-attachments"],
    ["/fixture/Other.xcresult", "/fixture/journey-attachments"],
    ["/fixture/HostedShellJourney.xcresult", "/fixture/other"],
  ])
    expect(() => attachmentExportArguments(...paths)).toThrow();
});

test("closed outcome sequence and two window names reject duplicate, gaps, paths and unknown attachments", () => {
  expect(selectJourneyAttachments(manifest([first])).outcomes).toHaveLength(1);
  for (const value of [
    [],
    [{ testIdentifier: "foreign", attachments: [first] }],
    manifest([first, first]),
    manifest([first, attachment("edith-journey-outcome-0003.json")]),
    manifest([first, attachment("edith-journey-desktop.png")]),
    manifest([
      first,
      attachment("edith-journey-storage-distribution.png", "../outside"),
    ]),
    manifest([first, attachment("edith-journey-outcome-0065.json")]),
    manifest([attachment("edith-journey-storage-distribution.png")]),
  ])
    expect(() => selectJourneyAttachments(value)).toThrow();
});

test("bounded actual exports retain the last cumulative proof without copying unrelated attachments", async () => {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "edith-journey-attachments-")),
  );
  try {
    const second = attachment("edith-journey-outcome-0002.json");
    await writeFile(
      join(directory, "manifest.json"),
      JSON.stringify(manifest([second, first])),
      { mode: 0o600 },
    );
    for (const [item, sequence, snapshots] of [
      [first, 1, []],
      [second, 2, [{ stage: "empty-idle" }]],
    ])
      await writeFile(
        join(directory, item.exportedFileName),
        JSON.stringify({
          schema: 1,
          sequence,
          startup: { stage: "before-registration" },
          snapshots,
        }),
        { mode: 0o600 },
      );
    await writeFile(join(directory, "unrelated.png"), Buffer.alloc(1));
    const result = await readJourneyAttachments(directory);
    expect(result.proof.sequence).toBe(2);
    expect(result.proof.snapshots).toEqual([{ stage: "empty-idle" }]);
    expect(result.images).toEqual([]);
    await expect(
      readJourneyAttachments(directory, { uid: process.getuid() + 1 }),
    ).rejects.toThrow();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("symlink, oversize, sequence mismatch and regressed proof fail rather than substituting success", async () => {
  for (const mode of ["symlink", "oversize", "sequence", "regression"]) {
    const directory = await mkdtemp(
      join(tmpdir(), "edith-journey-attachments-"),
    );
    try {
      const second = attachment("edith-journey-outcome-0002.json");
      await writeFile(
        join(directory, "manifest.json"),
        JSON.stringify(
          manifest(mode === "regression" ? [first, second] : [first]),
        ),
        { mode: 0o600 },
      );
      const path = join(directory, first.exportedFileName);
      if (mode === "symlink") {
        await writeFile(join(directory, "outside.json"), "{}");
        await symlink(join(directory, "outside.json"), path);
      } else if (mode === "oversize")
        await writeFile(path, Buffer.alloc(2_097_153));
      else
        await writeFile(
          path,
          JSON.stringify({
            schema: 1,
            sequence: mode === "sequence" ? 2 : 1,
            startup: {},
            snapshots: mode === "regression" ? [{ stage: "empty-idle" }] : [],
          }),
          { mode: 0o600 },
        );
      if (mode === "regression")
        await writeFile(
          join(directory, second.exportedFileName),
          JSON.stringify({
            schema: 1,
            sequence: 2,
            startup: {},
            snapshots: [],
          }),
          { mode: 0o600 },
        );
      await expect(readJourneyAttachments(directory)).rejects.toThrow();
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  }
});

test("official schema filename exports select human names and ignore framework attachments without reading their files", () => {
  const current = [
    {
      testIdentifier: journeyTestIdentifier,
      testIdentifierURL: "test://synthetic/owned",
      attachments: [
        {
          ...first,
          exportedFileName: "B21A.json",
          isAssociatedWithFailure: false,
          configurationName: "Debug",
          deviceName: "Synthetic Mac",
          deviceId: "synthetic",
          timestamp: 1,
        },
        attachment("Screenshot", "unrelated.png"),
      ],
    },
  ];
  expect(selectJourneyAttachments(current).outcomes[0].file).toBe("B21A.json");
});

test("export failures expose bounded categories without private command stderr", async () => {
  for (const [failure, category] of [
    [{ code: 1 }, "command-rejected"],
    [{ code: "ENOENT" }, "tool-unavailable"],
    [{ killed: true }, "timed-out"],
  ]) {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "edith-journey-export-")),
    );
    try {
      let received;
      try {
        await exportJourneyAttachments({
          resultBundle: join(root, "HostedShellJourney.xcresult"),
          outputDirectory: join(root, "journey-attachments"),
          run: async (_, args) => {
            if (args[1] === "version") return { stdout: toolVersion };
            if (args.includes("--schema")) return { stdout: toolSchema };
            throw Object.assign(Error("/private/synthetic-command"), failure);
          },
        });
      } catch (error) {
        received = error;
      }
      expect(received.phase).toBe("attachment-command");
      expect(received.category).toBe(category);
      expect(received.message).not.toContain("/private");
      expect(received.diagnostic.toolSchemaVersion).toBe("0.3.0");
      expect(received.diagnostic.requestedSchema).toBe("default");
      expect(JSON.stringify(received.diagnostic)).not.toContain("/private");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("asynchronous official export validates the supported schema and reads generated filenames", async () => {
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "edith-journey-export-")),
  );
  const outputDirectory = join(root, "journey-attachments");
  try {
    let command;
    const result = await exportJourneyAttachments({
      resultBundle: join(root, "HostedShellJourney.xcresult"),
      outputDirectory,
      run: async (executable, args, options) => {
        expect(options.maxBuffer).toBe(262_144);
        expect(options.timeout).toBe(
          args.includes("--schema") || args[1] === "version" ? 10_000 : 30_000,
        );
        if (args[1] === "version") return { stdout: toolVersion };
        if (args.includes("--schema")) return { stdout: toolSchema };
        command = [executable, ...args];
        await writeFile(
          join(outputDirectory, "manifest.json"),
          JSON.stringify([
            {
              testIdentifier: journeyTestIdentifier,
              attachments: [
                {
                  suggestedHumanReadableName: "edith-journey-outcome-0001.json",
                  exportedFileName: "D43B.json",
                  isAssociatedWithFailure: false,
                  configurationName: "Debug",
                  deviceName: "Synthetic Mac",
                  deviceId: "synthetic",
                },
              ],
            },
          ]),
          { mode: 0o600 },
        );
        await writeFile(
          join(outputDirectory, "D43B.json"),
          JSON.stringify({
            schema: 1,
            sequence: 1,
            startup: { stage: "registered" },
            snapshots: [],
          }),
          { mode: 0o600 },
        );
      },
    });
    expect(command).toEqual([
      "xcrun",
      ...attachmentExportArguments(
        join(root, "HostedShellJourney.xcresult"),
        outputDirectory,
      ),
    ]);
    expect(command).not.toContain("--filter");
    expect(result.proof.startup.stage).toBe("registered");
    expect(result.diagnostic.toolSchemaVersion).toBe("0.3.0");
    expect(result.diagnostic.schemaDigest).toMatch(/^[a-f0-9]{64}$/);
    expect(result.diagnostic.category).toBe("validated");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("runtime schema requires the exact consumed fields and reference chain", () => {
  expect(validateAttachmentToolSchema(toolSchema)).toMatch(/^[a-f0-9]{64}$/);
  for (const mutate of [
    (value) => {
      value.schemas.AttachmentDetails.type = "object";
    },
    (value) => {
      value.schemas.AttachmentDetails.items.$ref = "#/schemas/Foreign";
    },
    (value) => {
      delete value.schemas.TestAttachmentDetails.properties.testIdentifier;
    },
    (value) => {
      value.schemas.TestAttachmentDetails.required = ["attachments"];
    },
    (value) => {
      value.schemas.TestAttachmentDetails.properties.attachments.type =
        "object";
    },
    (value) => {
      value.schemas.TestAttachmentDetails.properties.attachments.items.$ref =
        "#/schemas/Foreign";
    },
    (value) => {
      value.schemas.Attachment.properties.exportedFileName.type = "integer";
    },
    (value) => {
      delete value.schemas.Attachment.properties.suggestedHumanReadableName;
    },
    (value) => {
      value.schemas.Attachment.required = ["exportedFileName"];
    },
  ]) {
    const value = JSON.parse(toolSchema);
    mutate(value);
    expect(() => validateAttachmentToolSchema(JSON.stringify(value))).toThrow();
  }
  for (const value of ["{}", "null", "invalid", " ".repeat(262_145)])
    expect(() => validateAttachmentToolSchema(value)).toThrow();
});

test("tool observations retain only closed bounded numeric versions", () => {
  expect(observeAttachmentToolVersion(toolVersion)).toEqual({
    toolVersion: "23000",
    toolSchemaVersion: "0.3.0",
  });
  expect(
    observeAttachmentToolVersion(
      "xcresulttool version 23000 (format version: 3.50)\n",
    ),
  ).toEqual({
    toolVersion: "23000",
    toolSchemaVersion: "unobserved",
  });
  expect(
    observeAttachmentToolVersion(
      "xcresulttool version 23000, schema version: /private/synthetic-secret",
    ),
  ).toEqual({
    toolVersion: "23000",
    toolSchemaVersion: "unobserved",
  });
  expect(
    JSON.stringify(
      observeAttachmentToolVersion(`${toolVersion}/private/synthetic-secret`),
    ),
  ).not.toContain("/private");
  for (const value of [
    "xcresulttool version /private/synthetic-secret",
    " ".repeat(262_145),
    "xcresulttool version 12345678901, schema version: 0.3.0",
  ])
    expect(() => observeAttachmentToolVersion(value)).toThrow();
});

test("known errors classify observed exact diagnostics and leave guesses unclassified", () => {
  const path = "/synthetic/HostedShellJourney.xcresult";
  for (const [failure, category] of [
    [
      { code: "ERR_CHILD_PROCESS_STDIO_MAXBUFFER", killed: true },
      "output-limit-exceeded",
    ],
    [
      { stderr: "Error: Unknown schema version provided: 999.0.0.\n" },
      "unsupported-schema",
    ],
    [
      {
        stderr: `Error: File or directory doesn't exist at path: ${path}.\nUsage: synthetic`,
      },
      "result-unreadable",
    ],
    [
      {
        stderr:
          "Error: File or directory doesn't exist at path: /synthetic/journey-attachments.\n",
      },
      "command-rejected",
    ],
    [
      {
        stderr:
          "unsupported schema invalid test unreadable bundle /private/synthetic-secret",
      },
      "command-rejected",
    ],
    [
      { stderr: "Error: Invalid test identifier: synthetic" },
      "command-rejected",
    ],
    [
      {
        stderr: `Error: Unknown schema version provided: 999.0.0.\n${" ".repeat(262_145)}`,
      },
      "command-rejected",
    ],
  ])
    expect(attachmentCommandFailureCategory(failure, path)).toBe(category);
});

test("incompatible or unbounded runtime discovery fails before exporting and retains no raw output", async () => {
  for (const [version, schema, phase] of [
    [
      "xcresulttool version /private/synthetic-secret",
      toolSchema,
      "attachment-tool",
    ],
    [toolVersion, "{}", "attachment-schema"],
    [toolVersion, " ".repeat(262_145), "attachment-schema"],
    [toolVersion, "invalid /private/synthetic-secret", "attachment-schema"],
  ]) {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "edith-journey-discovery-")),
    );
    try {
      const calls = [];
      let received;
      try {
        await exportJourneyAttachments({
          resultBundle: join(root, "HostedShellJourney.xcresult"),
          outputDirectory: join(root, "journey-attachments"),
          run: async (_, args) => {
            calls.push(args);
            return { stdout: args[1] === "version" ? version : schema };
          },
        });
      } catch (error) {
        received = error;
      }
      expect(received.phase).toBe(phase);
      expect(received.category).toBe("invalid-tool-format");
      expect(calls.some((args) => args.includes("--test-id"))).toBe(false);
      expect(JSON.stringify(received.diagnostic)).not.toContain("/private");
      expect(
        Buffer.byteLength(JSON.stringify(received.diagnostic)),
      ).toBeLessThan(512);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("failed tool discovery retains its actual phase and closed category", async () => {
  for (const phase of ["attachment-tool", "attachment-schema"]) {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "edith-journey-discovery-")),
    );
    try {
      let received;
      try {
        await exportJourneyAttachments({
          resultBundle: join(root, "HostedShellJourney.xcresult"),
          outputDirectory: join(root, "journey-attachments"),
          run: async (_, args) => {
            if (phase === "attachment-schema" && args[1] === "version")
              return { stdout: toolVersion };
            throw Object.assign(Error("/private/synthetic-secret"), {
              killed: true,
            });
          },
        });
      } catch (error) {
        received = error;
      }
      expect(received.phase).toBe(phase);
      expect(received.category).toBe("timed-out");
      expect(received.diagnostic.schemaDigest).toBe("unobserved");
      expect(JSON.stringify(received.diagnostic)).not.toContain("/private");
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});

test("manifest count, sequence and snapshot bounds remain enforced", async () => {
  const outcomes = Array.from({ length: 64 }, (_, index) =>
    attachment(
      `edith-journey-outcome-${String(index + 1).padStart(4, "0")}.json`,
    ),
  );
  expect(selectJourneyAttachments(manifest(outcomes)).outcomes).toHaveLength(
    64,
  );
  const maximum = [
    ...outcomes,
    ...Array.from({ length: 192 }, (_, index) =>
      attachment(`framework-${index}`, `framework-${index}.png`),
    ),
  ];
  expect(selectJourneyAttachments(manifest(maximum)).outcomes).toHaveLength(64);
  expect(() =>
    selectJourneyAttachments(manifest([...maximum, attachment("extra")])),
  ).toThrow();
  const root = await realpath(
    await mkdtemp(join(tmpdir(), "edith-journey-snapshot-bound-")),
  );
  try {
    await writeFile(
      join(root, "manifest.json"),
      JSON.stringify(manifest([first])),
      { mode: 0o600 },
    );
    for (const length of [13, 14]) {
      await writeFile(
        join(root, first.exportedFileName),
        JSON.stringify({
          schema: 1,
          sequence: 1,
          startup: {},
          snapshots: Array.from({ length }, () => ({ stage: "synthetic" })),
        }),
        { mode: 0o600 },
      );
      if (length === 13)
        expect(
          (await readJourneyAttachments(root)).proof.snapshots,
        ).toHaveLength(13);
      else await expect(readJourneyAttachments(root)).rejects.toThrow();
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("directory and manifest failures retain safe diagnostics without weakening outcomes", async () => {
  for (const mode of ["directory", "manifest", "sequence"]) {
    const root = await realpath(
      await mkdtemp(join(tmpdir(), "edith-journey-invalid-export-")),
    );
    try {
      const outputDirectory = join(root, "journey-attachments");
      if (mode === "directory")
        await writeFile(outputDirectory, "/private/synthetic-secret");
      let received;
      const calls = [];
      try {
        await exportJourneyAttachments({
          resultBundle: join(root, "HostedShellJourney.xcresult"),
          outputDirectory,
          run: async (_, args) => {
            calls.push(args);
            if (args[1] === "version") return { stdout: toolVersion };
            if (args.includes("--schema")) return { stdout: toolSchema };
            await writeFile(
              join(outputDirectory, "manifest.json"),
              mode === "manifest"
                ? "invalid /private/synthetic-secret"
                : JSON.stringify(manifest([first])),
              { mode: 0o600 },
            );
            if (mode === "sequence")
              await writeFile(
                join(outputDirectory, first.exportedFileName),
                JSON.stringify({
                  schema: 1,
                  sequence: 2,
                  startup: {},
                  snapshots: [],
                }),
                { mode: 0o600 },
              );
          },
        });
      } catch (error) {
        received = error;
      }
      expect(received.phase).toBe(
        mode === "directory" ? "attachment-directory" : "attachment-read",
      );
      expect(received.category).toBe(
        mode === "directory" ? "invalid-directory" : "invalid-export",
      );
      expect(received.diagnostic.schemaDigest).toMatch(
        mode === "directory" ? /^unobserved$/ : /^[a-f0-9]{64}$/,
      );
      expect(JSON.stringify(received.diagnostic)).not.toContain("/private");
      if (mode === "directory") expect(calls).toHaveLength(0);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  }
});
