import assert from "node:assert/strict";
import { createHash } from "node:crypto";

export const attachmentCommandOptions = {
  timeout: 10_000,
  maxBuffer: 262_144,
  encoding: "utf8",
};

export function boundedToolOutput(value) {
  assert(typeof value === "string" && Buffer.byteLength(value) <= 262_144);
  return value;
}

export function observeAttachmentToolVersion(stdout) {
  const output = boundedToolOutput(stdout);
  const match = /^xcresulttool version ([0-9]{1,10})(?:[,\s]|$)/.exec(output);
  assert(match);
  const schema =
    /, schema version: ([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(?:\s|$)/.exec(
      output,
    );
  return {
    toolVersion: match[1],
    toolSchemaVersion: schema?.[1] ?? "unobserved",
  };
}

export function validateAttachmentToolSchema(stdout) {
  const schema = JSON.parse(boundedToolOutput(stdout));
  const types = schema.schemas;
  assert(types && typeof types === "object");
  assert.equal(types.AttachmentDetails?.type, "array");
  assert.equal(
    types.AttachmentDetails.items?.$ref,
    "#/schemas/TestAttachmentDetails",
  );
  const test = types.TestAttachmentDetails;
  assert.equal(test?.type, "object");
  assert.equal(test.properties?.testIdentifier?.type, "string");
  assert.equal(test.properties?.attachments?.type, "array");
  assert.equal(test.properties.attachments.items?.$ref, "#/schemas/Attachment");
  assert(Array.isArray(test.required));
  assert(test.required.includes("testIdentifier"));
  assert(test.required.includes("attachments"));
  const attachment = types.Attachment;
  assert.equal(attachment?.type, "object");
  assert(Array.isArray(attachment.required));
  for (const name of ["exportedFileName", "suggestedHumanReadableName"]) {
    assert.equal(attachment.properties?.[name]?.type, "string");
    assert(attachment.required.includes(name));
  }
  return createHash("sha256").update(stdout).digest("hex");
}

export function attachmentCommandFailureCategory(error, resultBundle) {
  if (error.code === "ERR_CHILD_PROCESS_STDIO_MAXBUFFER")
    return "output-limit-exceeded";
  if (error.killed) return "timed-out";
  if (error.code === "ENOENT") return "tool-unavailable";
  const stderr = error.stderr;
  if (typeof stderr !== "string" || Buffer.byteLength(stderr) > 262_144)
    return "command-rejected";
  if (
    /^Error: Unknown schema version provided: [0-9]+\.[0-9]+\.[0-9]+\.\s*$/m.test(
      stderr,
    )
  )
    return "unsupported-schema";
  if (
    typeof resultBundle === "string" &&
    stderr
      .split(/\r?\n/)
      .includes(
        `Error: File or directory doesn't exist at path: ${resultBundle}.`,
      )
  )
    return "result-unreadable";
  return "command-rejected";
}
