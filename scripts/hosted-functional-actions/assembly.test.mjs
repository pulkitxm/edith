import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import {
  assembleFunctionalCaseSources,
  functionalCaseAssembly,
} from "./assembly.mjs";

const root = new URL("../../", import.meta.url).pathname;
const contextPath =
  "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift";
const transportPath =
  "Tests/HostedFunctionalActions/RuntimeSources/HostedFunctionalActionTransport.swift";
const casePath =
  "Tests/HostedFunctionalActions/OwnerCases/keepAwakeActionCase.swift";

test("actual native case assembly preserves original activation and the shared checked endpoint", async () => {
  const sources = await Promise.all(
    [contextPath, transportPath, casePath].map((path) =>
      readFile(root + path, "utf8"),
    ),
  );
  const result = functionalCaseAssembly("keepAwake", ...sources);
  assert.equal(result.length, 3);
  assert(
    result[1].source.includes(
      "try await endpoint.invoke(operation, payload: payload, timeout: timeout)",
    ),
  );
  assert(result[1].source.includes("try await verifyCurrent()"));
  assert(result[2].source.includes("rootView: KeepAwakeSettings"));
  assert(result[2].source.includes("accessibilityPerformPress"));
  assert(result[2].source.includes('readAuthoritative("keepAwake.ui.read")'));
  assert(
    result.every(
      ({ source }) => !source.includes("import FunctionalActionContract"),
    ),
  );
  assert.throws(() => functionalCaseAssembly("music", ...sources));
});

test("assembly is restricted to a private copied native test target and never overwrites source", async () => {
  const written = [];
  const admittedSnapshot = {
    sourceCommit: "a".repeat(40),
    files: await Promise.all(
      [contextPath, transportPath, casePath].map(async (path) => ({
        path,
        sha256: createHash("sha256")
          .update(await readFile(root + path))
          .digest("hex"),
      })),
    ),
  };
  const output = await assembleFunctionalCaseSources({
    root,
    owner: "keepAwake",
    admittedSnapshot,
    targetDirectory:
      "/private/synthetic/functional-native-assembly-123/Tests/OwnerTests",
    write: async (path, source, options) => {
      written.push({ path, source, options });
    },
    createDirectory: async () => {},
  });
  assert.equal(output.originalSourceFiles.length, 3);
  assert.equal(written.length, 3);
  assert(
    written.every(
      ({ options }) => options.flag === "wx" && options.mode === 0o600,
    ),
  );
  await assert.rejects(
    assembleFunctionalCaseSources({
      root,
      owner: "keepAwake",
      targetDirectory: root + "Extensions/keepAwake/Tests",
    }),
  );
  await assert.rejects(
    assembleFunctionalCaseSources({
      root,
      owner: "keepAwake",
      targetDirectory:
        "/private/synthetic/functional-native-assembly-123/Tests/OwnerTests",
      admittedSnapshot: {
        ...admittedSnapshot,
        files: admittedSnapshot.files.map((pin) => ({
          ...pin,
          sha256: "0".repeat(64),
        })),
      },
      write: async () => {
        throw new Error("Must not write unadmitted source");
      },
      createDirectory: async () => {
        throw new Error("Must not create unadmitted target");
      },
    }),
  );
});
