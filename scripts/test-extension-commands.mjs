import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionSupport } from "./build-extension-support.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-command-fixture-"));
try {
  const products = buildExtensionSupport(
    process.cwd(),
    "EdithExtensionSupport",
  );
  const bundle = join(root, "helper.bundle");
  const contents = join(bundle, "Contents");
  await mkdir(join(contents, "MacOS"), { recursive: true });
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-emit-library",
      "-parse-as-library",
      "-Osize",
      "-swift-version",
      "5",
      "-module-name",
      "EdithCommandFixture",
      "-target",
      "arm64-apple-macos14.0",
      resolve("Packages/EdithHost/Tests/CommandFixture/Runtime.swift"),
      "-I",
      join(products, "Modules"),
      "-L",
      products,
      "-lEdithExtensionSupport",
      "-Xlinker",
      "-dead_strip",
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      "@rpath/EdithCommandFixture",
      "-o",
      join(contents, "MacOS", "Runtime"),
    ],
    { env: { ...process.env, DEVELOPER_DIR: developer }, stdio: "inherit" },
  );
  const info = join(root, "info.json");
  await writeFile(
    info,
    JSON.stringify({
      CFBundleIdentifier: "com.pulkit.edith.extensions.keepAwake.helper",
      CFBundleExecutable: "Runtime",
      CFBundlePackageType: "BNDL",
      CFBundleShortVersionString: "1.0.0",
      EdithHostABI: "edith-host-1",
    }),
  );
  execFileSync("python3", [
    "-c",
    "import json,plistlib,sys; plistlib.dump(json.load(open(sys.argv[1])),open(sys.argv[2],'wb'))",
    info,
    join(contents, "Info.plist"),
  ]);
  execFileSync("codesign", ["--force", "--sign", "-", bundle], {
    stdio: "inherit",
  });
  const fixture = join(root, "host");
  await mkdir(fixture);
  const output = execFileSync(
    resolve("Packages/EdithHost/.build/debug/HostCommandHarness"),
    [fixture, resolve("local/minimal-host/Edith.app"), bundle],
    { encoding: "utf8", timeout: 60_000 },
  );
  const results = output
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    results.map(({ mode }) => mode),
    ["disable", "crash", "hang", "completed"],
  );
  for (const result of results) {
    assert.equal(result.sameAppExecutable, true);
    assert.equal(result.binaryInput, true);
    assert.equal(result.argumentsAndEnvironment, true);
    assert.equal(result.peerCommands, true);
    assert.equal(result.commandCancellation, true);
    assert.equal(result.remainingProcesses, 0);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
} finally {
  await rm(root, { recursive: true, force: true });
}
