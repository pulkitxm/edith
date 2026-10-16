import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { isAbsolute, join, posix } from "node:path";
import { functionalActionCasePaths } from "./owners.mjs";

export function functionalCaseAssembly(
  owner,
  contextSource,
  transportSource,
  caseSource,
  jsonSource,
) {
  const paths = functionalActionCasePaths(owner);
  assert(contextSource.includes("public struct HostedFunctionalActionContext"));
  assert(jsonSource.includes("public enum WorkerFixtureJSON"));
  assert.equal(
    (contextSource.match(/^import WorkerFixtureSupport$/gm) ?? []).length,
    1,
  );
  assert(transportSource.includes("endpoint = try ExtensionPeerEndpoint("));
  assert(caseSource.includes("HostedFunctionalActionCase"));
  assert(caseSource.includes(`static let owner = "${owner}"`));
  const removeImport = (text) => {
    const matches = text.match(/^import FunctionalActionContract$/gm) ?? [];
    assert.equal(matches.length, 1);
    return text.replace(/^import FunctionalActionContract\n/m, "");
  };
  return Object.freeze([
    {
      name: "HostedFunctionalActionContext.swift",
      source: contextSource.replace(/^import WorkerFixtureSupport\n/m, ""),
    },
    {
      name: "HostedFunctionalActionTransport.swift",
      source: removeImport(transportSource),
    },
    { name: paths.native.split("/").at(-1), source: removeImport(caseSource) },
    { name: "WorkerFixtureJSON.swift", source: jsonSource },
  ]);
}

export async function assembleFunctionalCaseSources({
  root,
  owner,
  targetDirectory,
  admittedSnapshot,
  read = readFile,
  write = writeFile,
  createDirectory = mkdir,
}) {
  assert(
    isAbsolute(targetDirectory) &&
      posix.normalize(targetDirectory) === targetDirectory,
  );
  assert(
    targetDirectory.includes("/functional-native-assembly-") &&
      !targetDirectory.endsWith("/"),
  );
  const paths = functionalActionCasePaths(owner);
  const sourcePaths = [
    "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift",
    "Tests/HostedFunctionalActions/RuntimeSources/HostedFunctionalActionTransport.swift",
    paths.native,
    "Extensions/fixtureSupport/WorkerFixtureJSON.swift",
  ];
  const sources = await Promise.all(
    sourcePaths.map((path) => read(join(root, path), "utf8")),
  );
  assert.match(admittedSnapshot.sourceCommit, /^[0-9a-f]{40}$/);
  assert.deepEqual(Object.keys(admittedSnapshot).sort(), [
    "files",
    "sourceCommit",
  ]);
  assert.deepEqual(
    admittedSnapshot.files.map((pin) => pin.path).sort(),
    [...sourcePaths].sort(),
  );
  for (const [index, path] of sourcePaths.entries()) {
    const pin = admittedSnapshot.files.find((item) => item.path === path);
    assert.deepEqual(Object.keys(pin).sort(), ["path", "sha256"]);
    assert.equal(
      createHash("sha256").update(sources[index]).digest("hex"),
      pin.sha256,
    );
  }
  const assembled = functionalCaseAssembly(owner, ...sources);
  await createDirectory(targetDirectory, { recursive: true, mode: 0o700 });
  for (const file of assembled)
    await write(join(targetDirectory, file.name), file.source, {
      flag: "wx",
      mode: 0o600,
    });
  for (const [index, path] of sourcePaths.entries())
    assert.equal(
      await read(join(root, path), "utf8"),
      sources[index],
      "Admitted native source changed during assembly",
    );
  return Object.freeze({
    owner,
    sourceCommit: admittedSnapshot.sourceCommit,
    originalSourceFiles: sourcePaths.map((path, index) => ({
      path,
      sha256: createHash("sha256").update(sources[index]).digest("hex"),
    })),
    copiedFiles: assembled.map(({ name, source }) => ({
      name,
      sha256: createHash("sha256").update(source).digest("hex"),
    })),
    scope:
      "compile into the owning native test target, original feature source is unchanged",
  });
}
