import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "./build-extension-support.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-native-task-fixture-"));
try {
  const products = buildExtensionSupport(
    process.cwd(),
    "EdithExtensionSupport",
    "NativeTaskFixture_app",
  );
  const source = join(root, "Runtime.swift");
  await writeFile(
    source,
    rewriteSupportImports(
      await readFile(
        "Packages/EdithHost/Tests/NativeTaskFixture/Runtime.swift",
        "utf8",
      ),
      products.modules,
    ),
  );
  const bundle = join(root, "app.bundle");
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
      "EdithNativeTaskFixture",
      "-target",
      "arm64-apple-macos14.0",
      source,
      "-I",
      join(products.products, "Modules"),
      "-L",
      products.products,
      `-l${products.product}`,
      "-Xlinker",
      "-dead_strip",
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      "@rpath/EdithNativeTaskFixture",
      "-o",
      join(contents, "MacOS", "Runtime"),
    ],
    { env: { ...process.env, DEVELOPER_DIR: developer }, stdio: "inherit" },
  );
  const info = join(root, "info.json");
  await writeFile(
    info,
    JSON.stringify({
      CFBundleIdentifier: "com.pulkit.edith.extensions.keepAwake.app",
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
    resolve("Packages/EdithHost/.build/debug/HostNativeTaskHarness"),
    [fixture, resolve("local/minimal-host/Edith.app"), bundle],
    { encoding: "utf8", timeout: 120_000 },
  );
  const result = JSON.parse(output.trim());
  for (const key of ["sameAppExecutable", "binaryStdio", "disabledAdmission", "malformedAdmission", "oversizeAdmission", "contextAdmission", "incompatibleAdmission", "uninstalledAdmission", "unownedAdmission", "tamperedAdmission", "parentExitCleanup", "cancelledDescendants"])
    assert.equal(result[key], true);
  assert.equal(result.remainingProcesses, 0);
  process.stdout.write(`${JSON.stringify(result)}\n`);
} finally {
  await rm(root, { recursive: true, force: true });
}
