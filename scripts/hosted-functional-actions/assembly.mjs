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
) {
  const paths = functionalActionCasePaths(owner);
  assert(contextSource.includes("public struct HostedFunctionalActionContext"));
  assert(transportSource.includes("endpoint = try ExtensionPeerEndpoint("));
  assert(caseSource.includes("HostedFunctionalActionCase"));
  assert(caseSource.includes(`static let owner = "${owner}"`));
  const removeImport = (text) => {
    const matches = text.match(/^import FunctionalActionContract$/gm) ?? [];
    assert.equal(matches.length, 1);
    return text.replace(/^import FunctionalActionContract\n/m, "");
  };
  return Object.freeze([
    { name: "HostedFunctionalActionContext.swift", source: contextSource },
    {
      name: "HostedFunctionalActionTransport.swift",
      source: removeImport(transportSource),
    },
    { name: paths.native.split("/").at(-1), source: removeImport(caseSource) },
  ]);
}

export async function assembleFunctionalCaseSources({
  root,
  owner,
  targetDirectory,
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
  ];
  const sources = await Promise.all(
    sourcePaths.map((path) => read(join(root, path), "utf8")),
  );
  const assembled = functionalCaseAssembly(owner, ...sources);
  await createDirectory(targetDirectory, { recursive: true, mode: 0o700 });
  for (const file of assembled)
    await write(join(targetDirectory, file.name), file.source, {
      flag: "wx",
      mode: 0o600,
    });
  return Object.freeze({
    owner,
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
