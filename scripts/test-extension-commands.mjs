import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { cp, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "./build-extension-support.mjs";
import { buildExtensionUICarrier } from "./build-extension-ui-carrier.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-command-fixture-"));
try {
  const products = buildExtensionSupport(
    process.cwd(),
    "EdithExtensionSupport",
    "CommandFixture_helper",
  );
  const source = join(root, "Runtime.swift");
  await writeFile(
    source,
    rewriteSupportImports(
      await readFile(
        "Packages/EdithHost/Tests/CommandFixture/Runtime.swift",
        "utf8",
      ),
      products.modules,
    ),
  );
  const payload = join(root, "keepAwake");
  const bundle = join(payload, "helper.bundle");
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
      EdithHostABI: "edith-host-2",
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
  const app = join(fixture, "Fixture.app");
  const identifier = `com.pulkit.edith.tests.command-${crypto.randomUUID()}`;
  await cp(resolve("local/minimal-host/Edith.app"), app, { recursive: true });
  execFileSync("python3", [
    "-c",
    "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['CFBundleIdentifier']=sys.argv[2]; d['CFBundleName']='Command Fixture'; plistlib.dump(d,open(p,'wb'))",
    join(app, "Contents/Info.plist"),
    identifier,
  ]);
  execFileSync("codesign", ["--force", "--sign", "-", app], {
    stdio: "inherit",
  });
  execFileSync("codesign", ["--verify", "--deep", "--strict", app], {
    stdio: "pipe",
  });
  await buildExtensionUICarrier({
    hostApp: app,
    payloadDirectory: payload,
    id: "keepAwake",
    version: "1.0.0",
    hostABI: "edith-host-2",
    development: true,
  });
  const output = execFileSync(
    resolve("Packages/EdithHost/.build/debug/HostCommandHarness"),
    [fixture, app, payload],
    { encoding: "utf8", timeout: 120_000 },
  );
  const results = output
    .trim()
    .split("\n")
    .map((line) => JSON.parse(line));
  assert.deepEqual(
    results.map(({ mode }) => mode),
    ["disable", "crash", "hang", "completed", "asyncStop", "asyncHang"],
  );
  for (const result of results) {
    assert.equal(result.sameAppExecutable, true);
    assert.equal(result.nestedHelperRole, true);
    assert.equal(result.carrierMetadata, true);
    assert.equal(result.signatureVerified, true);
    assert.equal(result.frozenExecutableProvenance, true);
    assert.equal(result.binaryInput, true);
    assert.equal(result.argumentsAndEnvironment, true);
    assert.equal(result.peerCommands, true);
    assert.equal(result.commandCancellation, true);
    assert.equal(result.boundedShutdown, true);
    assert.equal(result.isolatedSupportTypes, true);
    assert.equal(result.remainingProcesses, 0);
    process.stdout.write(`${JSON.stringify(result)}\n`);
  }
} finally {
  await rm(root, { recursive: true, force: true });
}
