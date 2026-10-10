import { expect, test } from "bun:test";
import { mkdtemp, realpath, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  attachmentExportArguments,
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

test("official exporter selects only the owned test and attachment prefix", () => {
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
    "--filter",
    "edith-journey-*",
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
