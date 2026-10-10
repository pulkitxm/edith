import { execFileSync } from "node:child_process";
import {
  access,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-native-policy-"));
try {
  const put = async (path, source) => {
    const file = join(root, path);
    await mkdir(resolve(file, ".."), { recursive: true });
    await writeFile(file, source);
  };
  for (const module of [
    "EdithCore",
    "EdithDatabase",
    "EdithKit",
    "EdithShared",
    "EdithCameraSupport",
    "EdithLidAwakeSupport",
  ])
    await mkdir(join(root, "Packages/Edith/Sources", module), {
      recursive: true,
    });
  await put("Packages/Edith/Package.swift", "");
  await put("Packages/ExtensionMarketplace/Package.swift", "");
  await put(
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    'public enum MarketplaceConfiguration { public static let hostABI = "fixture" }',
  );
  await put("scripts/link-shared-framework.py", "");
  await put("scripts/extension-host-build.mjs", "");
  await put(
    "Extensions/mock/Native/Package.swift",
    `// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "FixtureNative", platforms: [.macOS(.v14)], products: [.library(name: "FixtureNative", type: .dynamic, targets: ["FixtureNative"])], targets: [.target(name: "FixtureNative")])
`,
  );
  await put(
    "Extensions/mock/Native/Sources/FixtureNative/Runtime.swift",
    '@_cdecl("fixture_native_value") public func fixtureNativeValue() -> Int32 { 7 }',
  );
  const source = `import Darwin
import Foundation
@objc(NativePolicyFixtureRuntime) final class NativePolicyFixtureRuntime: NSObject {
    @objc func execute(_ input: NSDictionary) -> NSObject {
        guard input["operation"] as? String == "nativeProbe" else { return ["ok": false] as NSDictionary }
        let path = Bundle(for: Self.self).bundleURL.appendingPathComponent("Contents/Frameworks/libFixtureNative.dylib").path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { return ["ok": false] as NSDictionary }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "fixture_native_value") else { return ["ok": false] as NSDictionary }
        typealias Value = @convention(c) () -> Int32
        return ["ok": unsafeBitCast(symbol, to: Value.self)() == 7] as NSDictionary
    }
}
@_cdecl("edith_extension_create") public func createFixtureExtension() -> UnsafeMutableRawPointer? { Unmanaged.passRetained(NativePolicyFixtureRuntime()).toOpaque() }
`;
  await put("Extensions/mock/Runtime.swift", source);
  const definition = {
    id: "mock",
    version: "1.0.0",
    contractVersion: 1,
    hostABI: "edith-host-1",
    minimumSystemVersion: 14,
    roles: {
      app: ["Extensions/mock/Runtime.swift"],
      helper: ["Extensions/mock/Runtime.swift"],
    },
    nativePackage: "Extensions/mock/Native",
    nativeProduct: "FixtureNative",
    nativeRoles: ["app"],
    nativeLink: false,
    inputs: ["Extensions/mock"],
    sharedInputs: [],
    dependencies: [],
  };
  await put("Extensions/manifest.json", JSON.stringify([definition]));
  await buildExtensionPackage({
    root,
    id: "mock",
    output: join(root, "output"),
    development: true,
  });
  const payload = join(root, "unpacked");
  execFileSync("ditto", ["-xk", join(root, "output/mock.zip"), payload]);
  const app = join(payload, "mock/app.bundle");
  const helper = join(payload, "mock/helper.bundle");
  await access(join(app, "Contents/Frameworks/libFixtureNative.dylib"));
  try {
    await access(join(helper, "Contents/Frameworks/libFixtureNative.dylib"));
    throw new Error("Native payload leaked into an unselected role");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  for (const bundle of [app, helper]) {
    execFileSync("codesign", ["--verify", "--strict", "--deep", bundle]);
    const linkage = execFileSync(
      "otool",
      ["-L", join(bundle, "Contents/MacOS/Runtime")],
      { encoding: "utf8" },
    );
    if (linkage.includes("FixtureNative"))
      throw new Error("A lazy native product was linked eagerly");
  }
  const probe = `import Darwin
import Foundation
let path = CommandLine.arguments[1]
guard let handle = dlopen(path + "/Contents/MacOS/Runtime", RTLD_NOW | RTLD_LOCAL), let symbol = dlsym(handle, "edith_extension_create") else { exit(1) }
typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
guard let pointer = unsafeBitCast(symbol, to: Factory.self)() else { exit(2) }
let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
guard let result = object.perform(NSSelectorFromString("execute:"), with: ["operation": "nativeProbe"] as NSDictionary)?.takeUnretainedValue() as? NSDictionary, result["ok"] as? Bool == true else { exit(3) }
`;
  await put("probe.swift", probe);
  execFileSync("xcrun", [
    "swiftc",
    join(root, "probe.swift"),
    "-o",
    join(root, "probe"),
  ]);
  execFileSync(join(root, "probe"), [app]);
  const manifest = JSON.parse(
    await readFile(join(payload, "mock/package.json"), "utf8"),
  );
  if (manifest.id !== "mock")
    throw new Error("Fixture package identity changed");
  process.stdout.write(
    `${JSON.stringify({ selectedRoleNativePayloadValidated: true, unselectedRolePayloadAbsent: true, eagerNativeLinkageAbsent: true, relocatedLazyNativeInferenceLoaded: true, strictSignedRolesValidated: true })}\n`,
  );
} finally {
  await rm(root, { recursive: true, force: true });
}
