import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { requireCleanSparkleSources } from "./hosted-sparkle-update/build-host.mjs";

test("dirty and additional build inputs cannot be attributed to the declared fixture commit", () => {
  const calls = [];
  requireCleanSparkleSources((command, args, options) => {
    calls.push({ command, args, options });
    return "";
  });
  expect(calls).toEqual([
    {
      command: "git",
      args: [
        "status",
        "--porcelain",
        "--untracked-files=all",
        "--",
        "Packages",
        "Extensions",
        "scripts",
        "Tests",
      ],
      options: { encoding: "utf8" },
    },
  ]);
  for (const result of [
    " M Packages/EdithHost/Sources/EdithHost/HostEntry.swift\n",
    "?? Packages/ExtensionSupport/Sources/EdithExtensionSupport/Foreign.swift\n",
    " M Extensions/calendar/Runtime.swift\n",
    "?? Tests/HostedSparkleUpdate/FixtureSources/Other.swift\n",
  ])
    expect(() => requireCleanSparkleSources(() => result)).toThrow();
  expect(() =>
    requireCleanSparkleSources(() => {
      throw Error("git source inspection failed");
    }),
  ).toThrow();
});

test("copied host compilation retains the closed dependency relocation and dedicated fixture qualifier", async () => {
  const source = await readFile(
    "scripts/hosted-sparkle-update/build-host.mjs",
    "utf8",
  );
  expect(source).toContain('from "../hosted-host-manifest.mjs"');
  expect(source).toContain(
    'await readPinned("Packages/EdithHost/Package.swift")',
  );
  expect(source).toContain(
    'await readPinned("scripts/build-minimal-host.mjs")',
  );
  expect(source).toContain('"-DEDITH_HOSTED_SPARKLE_FIXTURE"');
  expect(source).toContain('"HostEntry.swift"');
  expect(source).toContain('"HostUpdater.swift"');
  expect(source).toContain("productionExecutableUnchangedProof: false");
  expect(source).toContain("actualSparkleInstallValidated: false");
});
