import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { lstat, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { promisify } from "node:util";
import {
  attachmentCommandFailureCategory,
  attachmentCommandOptions,
  observeAttachmentToolVersion,
  validateAttachmentToolSchema,
} from "./attachment-tool.mjs";
import { journeyImageNames } from "./evidence.mjs";

export const journeyTestIdentifier =
  "OriginalShellJourneyTests/testOriginalCalendarInstallCustomizeReplaceUpdateDisableAndRemove()";

export function attachmentExportArguments(resultBundle, outputDirectory) {
  for (const path of [resultBundle, outputDirectory]) {
    assert.equal(resolve(path), path);
    assert(!/[\0\r\n]/.test(path));
  }
  assert(resultBundle.endsWith("/HostedShellJourney.xcresult"));
  assert(outputDirectory.endsWith("/journey-attachments"));
  return [
    "xcresulttool",
    "export",
    "attachments",
    "--test-id",
    journeyTestIdentifier,
    "--path",
    resultBundle,
    "--output-path",
    outputDirectory,
  ];
}

export function selectJourneyAttachments(manifest) {
  assert(Array.isArray(manifest) && manifest.length === 1);
  const test = manifest[0];
  assert.equal(test.testIdentifier, journeyTestIdentifier);
  assert(
    Array.isArray(test.attachments) &&
      test.attachments.length > 0 &&
      test.attachments.length <= 256,
  );
  const names = new Set();
  const files = new Set();
  const result = [];
  for (const attachment of test.attachments) {
    const name = attachment.suggestedHumanReadableName;
    const file = attachment.exportedFileName;
    assert(typeof name === "string" && name.length <= 128);
    assert(typeof file === "string" && /^[A-Za-z0-9._-]{1,255}$/.test(file));
    assert.equal(basename(file), file);
    if (!name.startsWith("edith-journey-")) continue;
    assert(!names.has(name) && !files.has(file));
    names.add(name);
    files.add(file);
    const match = /^edith-journey-outcome-(\d{4})\.json$/.exec(name);
    if (match) {
      const sequence = Number(match[1]);
      assert(sequence >= 1 && sequence <= 64);
      result.push({
        kind: "outcome",
        name,
        file,
        sequence,
        maximumBytes: 2_097_152,
      });
    } else {
      const image = name.replace(/^edith-journey-/, "");
      assert.equal(name, `edith-journey-${image}`);
      assert(journeyImageNames.includes(image));
      result.push({
        kind: "image",
        name: image,
        file,
        maximumBytes: 8_388_608,
      });
    }
  }
  const outcomes = result
    .filter(({ kind }) => kind === "outcome")
    .sort((a, b) => a.sequence - b.sequence);
  assert(outcomes.length > 0);
  assert(outcomes.every(({ sequence }, index) => sequence === index + 1));
  return { outcomes, images: result.filter(({ kind }) => kind === "image") };
}

export async function readJourneyAttachments(
  directory,
  { uid = process.getuid() } = {},
) {
  assert.equal(await realpath(directory), directory);
  const info = await lstat(directory);
  assert(info.isDirectory() && !info.isSymbolicLink() && info.uid === uid);
  const readOwned = async (file, maximumBytes) => {
    assert(/^[A-Za-z0-9._-]{1,255}$/.test(file));
    const path = join(directory, file);
    const info = await lstat(path);
    assert(info.isFile() && !info.isSymbolicLink() && info.uid === uid);
    assert(
      info.size > 0 && info.size <= maximumBytes && (info.mode & 0o022) === 0,
    );
    assert.equal(await realpath(path), path);
    const bytes = await readFile(path);
    assert.equal(bytes.length, info.size);
    return bytes;
  };
  const selected = selectJourneyAttachments(
    JSON.parse(await readOwned("manifest.json", 262_144)),
  );
  let total = 0;
  let proof;
  for (const attachment of selected.outcomes) {
    const bytes = await readOwned(attachment.file, attachment.maximumBytes);
    total += bytes.length;
    assert(total <= 33_554_432);
    const next = JSON.parse(bytes);
    assert.equal(next.schema, 1);
    assert.equal(next.sequence, attachment.sequence);
    assert(next.startup && typeof next.startup === "object");
    assert(Array.isArray(next.snapshots) && next.snapshots.length <= 13);
    assert(!proof || next.snapshots.length >= proof.snapshots.length);
    proof = next;
  }
  return { proof, images: selected.images, readOwned };
}

export async function exportJourneyAttachments({
  resultBundle,
  outputDirectory,
  run = promisify(execFile),
}) {
  const diagnostic = {
    schema: 1,
    requestedSchema: "default",
    toolVersion: "unobserved",
    toolSchemaVersion: "unobserved",
    schemaDigest: "unobserved",
    manifestContract: "owned-human-names-v1",
    phase: "attachment-directory",
    category: "invalid-directory",
  };
  const reject = (message, phase, category) => {
    diagnostic.phase = phase;
    diagnostic.category = category;
    return Object.assign(Error(message), {
      phase,
      category,
      diagnostic: { ...diagnostic },
    });
  };
  try {
    attachmentExportArguments(resultBundle, outputDirectory);
    await mkdir(outputDirectory, { recursive: false, mode: 0o700 });
  } catch {
    throw reject(
      "Attachment export directory rejected",
      "attachment-directory",
      "invalid-directory",
    );
  }
  for (const [phase, args, observe] of [
    [
      "attachment-tool",
      ["xcresulttool", "version"],
      (stdout) => {
        Object.assign(diagnostic, observeAttachmentToolVersion(stdout));
      },
    ],
    [
      "attachment-schema",
      ["xcresulttool", "export", "attachments", "--schema"],
      (stdout) => {
        diagnostic.schemaDigest = validateAttachmentToolSchema(stdout);
      },
    ],
  ]) {
    let stdout;
    try {
      ({ stdout } = await run("xcrun", args, attachmentCommandOptions));
    } catch (error) {
      throw reject(
        "Attachment tool discovery rejected",
        phase,
        attachmentCommandFailureCategory(error),
      );
    }
    try {
      observe(stdout);
    } catch {
      throw reject(
        "Attachment tool format rejected",
        phase,
        "invalid-tool-format",
      );
    }
  }
  try {
    await run(
      "xcrun",
      attachmentExportArguments(resultBundle, outputDirectory),
      {
        ...attachmentCommandOptions,
        timeout: 30_000,
      },
    );
  } catch (error) {
    throw reject(
      "Attachment export command rejected",
      "attachment-command",
      attachmentCommandFailureCategory(error, resultBundle),
    );
  }
  try {
    const attachments = await readJourneyAttachments(outputDirectory);
    diagnostic.phase = "attachment-read";
    diagnostic.category = "validated";
    return { ...attachments, diagnostic: { ...diagnostic } };
  } catch {
    throw reject(
      "Attachment manifest rejected",
      "attachment-read",
      "invalid-export",
    );
  }
}

export async function retainJourneyAttachmentProof(attachments, output) {
  const bytes = Buffer.from(JSON.stringify(attachments.proof));
  assert(bytes.length <= 2_097_152);
  await writeFile(join(output, "journey-outcome.json"), bytes, {
    mode: 0o600,
    flag: "wx",
  });
}
