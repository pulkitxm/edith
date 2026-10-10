import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

const output = resolve("local/hosted-managed-native");
const contract = resolve(
  "Tests/HostedManagedNativeProbe/Sources/ProbeContract/ProbeContract.swift",
);
const hostSource = resolve("scripts/hosted-managed-native/ProbeHost.swift");
const uiSource = resolve(
  "Tests/HostedManagedNativeProbe/UITests/ManagedNativeUITests.swift",
);
await mkdir(output, { recursive: true });

if (process.argv.includes("--check")) {
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-typecheck",
      "-parse-as-library",
      "-target",
      "arm64-apple-macos14.0",
      contract,
      hostSource,
    ],
    { stdio: "inherit" },
  );
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-typecheck",
      "-parse-as-library",
      "-target",
      "arm64-apple-macos14.0",
      "-F",
      `${process.env.DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/Library/Frameworks`,
      "-I",
      `${process.env.DEVELOPER_DIR}/Platforms/MacOSX.platform/Developer/usr/lib`,
      contract,
      uiSource,
    ],
    { stdio: "inherit" },
  );
  process.exit(0);
}

if (!process.argv.includes("--build-only")) {
  assert.equal(process.env.GITHUB_ACTIONS, "true");
  assert.equal(process.env.RUNNER_OS, "macOS");
  assert.equal(process.env.RUNNER_ENVIRONMENT, "github-hosted");
  assert.equal(process.env.EDITH_HOSTED_MANAGED_PROBE, "1");
}
const packageDirectory = join(output, "HostPackage");
await mkdir(packageDirectory);
await cp(
  resolve("Packages/EdithHost/Sources"),
  join(packageDirectory, "Sources"),
  { recursive: true },
);
await cp(resolve("Packages/EdithHost/Tests"), join(packageDirectory, "Tests"), {
  recursive: true,
});
let manifest = await readFile("Packages/EdithHost/Package.swift", "utf8");
for (const dependency of ["ExtensionMarketplace", "ExtensionSupport"])
  manifest = manifest.replace(
    `.package(path: "../${dependency}")`,
    `.package(path: ${JSON.stringify(resolve("Packages", dependency))})`,
  );
await writeFile(join(packageDirectory, "Package.swift"), manifest);
const entryPath = join(packageDirectory, "Sources/EdithHost/HostEntry.swift");
const entry = await readFile(entryPath, "utf8");
const anchor = "        #if EDITH_CLI_FIXTURE\n";
assert.equal(entry.split(anchor).length, 2);
const overlay = `${anchor}        if arguments.count == 2, ["--extension-hosted-approval-probe", "--extension-hosted-register-probe"].contains(arguments[0]) {\n            do {\n                let directory = URL(fileURLWithPath: arguments[1])\n                if arguments[0] == "--extension-hosted-register-probe" {\n                    try HostedManagedApprovalProbe.register(directory: directory)\n                } else {\n                    try HostedManagedApprovalProbe.run(directory: directory)\n                }\n            } catch {\n                FileHandle.standardError.write(Data("Hosted probe admission failed: \\(error)\\n".utf8))\n                exit(1)\n            }\n            return\n        }\n`;
await writeFile(entryPath, entry.replace(anchor, overlay));
await cp(
  hostSource,
  join(packageDirectory, "Sources/EdithHost/HostedManagedApprovalProbe.swift"),
);
await cp(
  contract,
  join(packageDirectory, "Sources/EdithHost/ProbeContract.swift"),
);
let builder = await readFile("scripts/build-minimal-host.mjs", "utf8");
builder = builder.replace(
  '"./build-extension-ui-carrier.mjs"',
  JSON.stringify(
    pathToFileURL(resolve("scripts/build-extension-ui-carrier.mjs")).href,
  ),
);
builder = builder.replace(
  'resolve(root, "Packages/EdithHost")',
  JSON.stringify(packageDirectory),
);
builder = builder.replace(
  'resolve(root, "local/minimal-host/Edith.app")',
  JSON.stringify(join(output, "frozen/Edith.app")),
);
builder = builder.replace(
  '  "--product",\n',
  '  "-Xswiftc",\n  "-DEDITH_CLI_FIXTURE",\n  "--product",\n',
);
const builderPath = join(output, "build-host.mjs");
await writeFile(builderPath, builder);
execFileSync(process.execPath, [builderPath], { stdio: "inherit" });
const products = execFileSync(
  "swift",
  [
    "build",
    "--package-path",
    packageDirectory,
    "--build-system",
    "native",
    "--configuration",
    "release",
    "--show-bin-path",
  ],
  { encoding: "utf8" },
).trim();
const receipt = {
  sourceCommit: execFileSync("git", ["rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim(),
  fixtureExecutable: join(products, "EdithHost"),
  frozenHost: join(output, "frozen/Edith.app"),
  productionExecutableUnchangedProof: false,
  originalHostEntrySHA256: createHash("sha256").update(entry).digest("hex"),
  probeHostEntrySHA256: createHash("sha256")
    .update(entry.replace(anchor, overlay))
    .digest("hex"),
  overlayPurpose:
    "Standalone hosted public approval browser entry; original role dispatch and admission unchanged",
};
await writeFile(join(output, "build-receipt.json"), JSON.stringify(receipt));
