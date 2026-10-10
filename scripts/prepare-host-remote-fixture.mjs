import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  copyFile,
  cp,
  mkdir,
  readdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "./build-extension-support.mjs";
import {
  buildExtensionUICarrier,
  extensionUIExtensionPoint,
} from "./build-extension-ui-carrier.mjs";

const run = (command, arguments_) =>
  execFileSync(command, arguments_, { stdio: "pipe" });

async function plist(path, value) {
  await mkdir(dirname(path), { recursive: true });
  run("python3", [
    "-c",
    "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
    JSON.stringify(value),
    path,
  ]);
}

export async function prepareHostRemoteFixture({
  root,
  directory,
  sourceHost,
  sourceExecutable,
  identifier,
  version = "1.0.0",
  retainedVersions = [],
}) {
  assert.match(version, /^\d{1,8}\.\d{1,8}\.\d{1,8}$/);
  assert(retainedVersions.length < 8);
  assert.equal(
    new Set([...retainedVersions, version]).size,
    retainedVersions.length + 1,
  );
  for (const retained of retainedVersions)
    assert.match(retained, /^\d{1,8}\.\d{1,8}\.\d{1,8}$/);
  assert.match(
    identifier,
    /^com\.pulkit\.edith\.tests\.remote-[a-z0-9-]{1,60}$/,
  );
  directory = resolve(directory);
  assert(
    directory.startsWith(
      join(homedir(), "Applications", "Edith Remote Fixture "),
    ),
  );
  const identityOutput = run("security", [
    "find-identity",
    "-v",
    "-p",
    "codesigning",
  ]).toString();
  const identities = identityOutput.match(/\b[0-9A-F]{40}\b/g) ?? [];
  assert.equal(
    identities.length,
    1,
    "A single configured development signing identity is required",
  );
  const signingIdentity = identities[0];
  const sign = (path, entitlements) =>
    run("codesign", [
      "--force",
      "--sign",
      signingIdentity,
      "--timestamp=none",
      "--options",
      "runtime",
      ...(entitlements ? ["--entitlements", entitlements] : []),
      path,
    ]);
  async function signRuntime(path) {
    for (const entry of await readdir(path, { withFileTypes: true })) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await signRuntime(child);
      else if (
        entry.isFile() &&
        run("file", ["-b", child]).toString().includes("Mach-O")
      )
        sign(child);
    }
    if (/\.(framework|xpc|app)$/.test(path)) sign(path);
  }
  const app = join(directory, "Host.app");
  await mkdir(directory, { recursive: true });
  await cp(sourceHost, app, {
    recursive: true,
    errorOnExist: true,
    force: false,
  });
  const products = run("swift", [
    "build",
    "--package-path",
    join(root, "Packages/EdithHost"),
    "--build-system",
    "native",
    "--configuration",
    "release",
    "--show-bin-path",
  ])
    .toString()
    .trim();
  const executable = join(app, "Contents/MacOS/Edith");
  await copyFile(sourceExecutable ?? join(products, "EdithHost"), executable);
  const links = run("otool", ["-L", executable]).toString();
  for (const line of links.split("\n").slice(1)) {
    const dependency = line.trim().split(" ")[0];
    if (dependency.endsWith("/Sparkle.framework/Versions/B/Sparkle"))
      run("install_name_tool", [
        "-change",
        dependency,
        "@rpath/Sparkle.framework/Sparkle",
        executable,
      ]);
  }
  for (const path of [
    "@executable_path/../Frameworks",
    "@executable_path/../../../../Frameworks",
  ])
    run("install_name_tool", ["-add_rpath", path, executable]);
  const loadCommands = run("otool", ["-l", executable]).toString();
  for (const match of loadCommands.matchAll(
    /cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+) \(offset/g,
  )) {
    if (
      match[1].startsWith("/") &&
      !match[1].startsWith("/usr/") &&
      !match[1].startsWith("/System/")
    )
      run("install_name_tool", ["-delete_rpath", match[1], executable]);
  }
  run("strip", ["-rSTx", executable]);
  const hostInfo = JSON.parse(
    run("python3", [
      "-c",
      "import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
      join(app, "Contents/Info.plist"),
    ]).toString(),
  );
  await plist(join(app, "Contents/Info.plist"), {
    ...hostInfo,
    CFBundleIdentifier: identifier,
    CFBundleName: "Synthetic owned remote scene",
    CFBundleDisplayName: "Synthetic owned remote scene",
  });
  await plist(
    join(app, "Contents/Extensions/ExtensionUI.appextensionpoints"),
    extensionUIExtensionPoint(identifier),
  );
  await signRuntime(join(app, "Contents/Frameworks"));
  sign(app);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  const configuration = await readFile(
    join(
      root,
      "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    ),
    "utf8",
  );
  const hostABI = /workerHostABI = "([^"]+)"/.exec(configuration)?.[1];
  assert(hostABI);
  const slot = identifier.slice("com.pulkit.edith.tests.".length);
  const identityRoot = join(directory, "support/Edith Tests", slot);
  let carrier;
  let worker;
  const packages = [];
  for (const fixtureVersion of [...retainedVersions, version]) {
    const payloadDirectory = join(
      identityRoot,
      "Extensions/sample",
      hostABI,
      `arm64/${fixtureVersion}/sample`,
    );
    const contents = join(payloadDirectory, "app.bundle/Contents");
    await mkdir(join(contents, "MacOS"), { recursive: true });
    const support = buildExtensionSupport(
      root,
      "EdithExtensionUI",
      "RemoteFixture_app",
    );
    const source = join(directory, `Runtime-${fixtureVersion}.swift`);
    await writeFile(
      source,
      rewriteSupportImports(
        (
          await readFile(
            join(root, "Packages/EdithHost/Tests/RemoteFixture/Runtime.swift"),
            "utf8",
          )
        )
          .replaceAll("HOST_ABI", hostABI)
          .replaceAll("FIXTURE_VERSION", fixtureVersion),
        support.modules,
      ),
    );
    run("xcrun", [
      "swiftc",
      "-emit-library",
      "-parse-as-library",
      "-Osize",
      "-swift-version",
      "5",
      "-module-name",
      "EdithRemoteFixture",
      "-target",
      "arm64-apple-macos14.0",
      "-plugin-path",
      `${process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer"}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
      source,
      "-I",
      join(support.products, "Modules"),
      "-L",
      support.products,
      `-l${support.product}`,
      "-Xlinker",
      "-dead_strip",
      "-Xlinker",
      "-exported_symbol",
      "-Xlinker",
      "_edith_extension_create",
      "-Xlinker",
      "-exported_symbol",
      "-Xlinker",
      "_edith_extension_presentation_create",
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      "@rpath/EdithRemoteFixture",
      "-o",
      join(contents, "MacOS/Runtime"),
    ]);
    await plist(join(contents, "Info.plist"), {
      CFBundleIdentifier: "com.pulkit.edith.extensions.sample.app",
      CFBundleExecutable: "Runtime",
      CFBundlePackageType: "BNDL",
      CFBundleShortVersionString: fixtureVersion,
      EdithHostABI: hostABI,
    });
    sign(join(payloadDirectory, "app.bundle"));
    const package_ = {
      id: "sample",
      version: fixtureVersion,
      hostABI,
      architecture: "arm64",
      minimumSystemVersion: 14,
      downloadURL:
        "https://github.com/pulkitxm/edith/releases/download/fixture/sample.zip",
      sha256: "0".repeat(64),
      downloadBytes: 1,
      installedBytes: 1,
      dependencies: [],
    };
    packages.push(package_);
    await buildExtensionUICarrier({
      hostApp: app,
      payloadDirectory,
      id: "sample",
      version: fixtureVersion,
      hostABI,
      development: true,
    });
    carrier = join(payloadDirectory, "ExtensionCarrier.app");
    worker = join(carrier, "Contents/Extensions/ExtensionWorker.appex");
    const entitlements = join(directory, "sandbox.plist");
    await plist(entitlements, { "com.apple.security.app-sandbox": true });
    await signRuntime(join(carrier, "Contents/Frameworks"));
    sign(worker, entitlements);
    sign(carrier);
    run("codesign", ["--verify", "--deep", "--strict", carrier]);
  }
  await writeFile(
    join(directory, "selected-package.json"),
    JSON.stringify(packages.at(-1)),
  );
  await writeFile(
    join(directory, "retained-packages.json"),
    JSON.stringify(packages.slice(0, -1)),
  );
  const result = {
    directory: await realpath(directory),
    app,
    executable,
    carrier,
    worker,
    identifier,
    hostABI,
    retainedVersions,
  };
  await writeFile(join(directory, "fixture.json"), JSON.stringify(result));
  return result;
}

if (resolve(process.argv[1] ?? "") === fileURLToPath(import.meta.url)) {
  const [directory, sourceHost, identifier, version, ...retainedVersions] =
    process.argv.slice(2);
  assert(
    directory && sourceHost && identifier,
    "Usage: prepare-host-remote-fixture.mjs directory frozen-host identifier [version]",
  );
  console.log(
    JSON.stringify(
      await prepareHostRemoteFixture({
        root: process.cwd(),
        directory,
        sourceHost,
        identifier,
        version,
        retainedVersions,
      }),
    ),
  );
}
