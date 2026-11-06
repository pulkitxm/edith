import { execFileSync } from "node:child_process";
import {
  access,
  mkdir,
  mkdtemp,
  readdir,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { buildExtensionPackage } from "./build-extension-package.mjs";
import { workerHostABI } from "./extension-host-abi.mjs";

const root = await mkdtemp(join(tmpdir(), "extension-native-policy-"));
try {
  const put = async (path, source) => {
    const file = join(root, path);
    await mkdir(resolve(file, ".."), { recursive: true });
    await writeFile(file, source);
  };
  await put("Packages/ExtensionMarketplace/Package.swift", "");
  await put(
    "Packages/ExtensionMarketplace/Sources/ExtensionMarketplace/MarketplaceConfiguration.swift",
    'public enum MarketplaceConfiguration { public static let hostABI = "fixture" }',
  );
  await put(
    "Extensions/mock/Native/Package.swift",
    `// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "FixtureNative", platforms: [.macOS(.v14)], products: [.library(name: "FixtureNative", type: .dynamic, targets: ["FixtureNative"])], targets: [.target(name: "FixtureNative")])
`,
  );
  await put(
    "Extensions/mock/Native/Sources/FixtureNative/Runtime.swift",
    `import Darwin
@_cdecl("fixture_native_value") public func fixtureNativeValue() -> Int32 { 7 }
public func fixtureNativeImagePath() -> String {
    var info = Dl_info()
    guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return "" }
    return String(cString: name)
}
`,
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
  await put(
    "Extensions/linked/Runtime.swift",
    `import Foundation
import FixtureNative
final class LinkedNativeFixtureRuntime: NSObject {
    @objc func execute(_ input: NSDictionary) -> NSObject {
        ["image": fixtureNativeImagePath()] as NSDictionary
    }
}
@_cdecl("edith_extension_create") public func createLinkedFixtureExtension() -> UnsafeMutableRawPointer? { Unmanaged.passRetained(LinkedNativeFixtureRuntime()).toOpaque() }
`,
  );
  const definition = {
    id: "mock",
    version: "1.0.0",
    contractVersion: 1,
    hostABI: workerHostABI,
    minimumSystemVersion: "14.0.0",
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
  const linked = ["alpha", "beta"].map((id) => ({
    ...definition,
    id,
    roles: { app: ["Extensions/linked/Runtime.swift"] },
    nativeRoles: undefined,
    nativeLink: undefined,
    inputs: ["Extensions/linked"],
  }));
  await put(
    "Extensions/manifest.json",
    JSON.stringify([definition, ...linked]),
  );
  const payload = join(root, "unpacked");
  for (const { id } of [definition, ...linked]) {
    await buildExtensionPackage({
      root,
      id,
      output: join(root, "output"),
      development: true,
      developmentHostRoot: process.cwd(),
    });
    execFileSync("ditto", ["-xk", join(root, `output/${id}.zip`), payload]);
  }
  const installName = (path) =>
    execFileSync("otool", ["-D", path], { encoding: "utf8" })
      .split("\n")[1]
      .trim();
  const linkedLibraries = [];
  for (const { id } of linked) {
    const bundle = join(payload, id, "app.bundle");
    const frameworks = join(bundle, "Contents/Frameworks");
    const [library, ...others] = await readdir(frameworks);
    if (
      others.length ||
      !/^libFixtureNative\.[a-z]+-[0-9a-f]{16}\.dylib$/.test(library) ||
      !library.includes(`.${id}-`)
    )
      throw new Error("A linked native product kept a shared file name");
    const name = installName(join(frameworks, library));
    if (name !== `@rpath/${library}`)
      throw new Error("A linked native product kept a shared install name");
    const linkage = execFileSync(
      "otool",
      ["-L", join(bundle, "Contents/MacOS/Runtime")],
      { encoding: "utf8" },
    );
    if (
      !linkage.includes(name) ||
      linkage.includes("@rpath/libFixtureNative.dylib")
    )
      throw new Error("A runtime does not link its own native product");
    execFileSync("codesign", ["--verify", "--strict", "--deep", bundle]);
    linkedLibraries.push(name);
  }
  if (new Set(linkedLibraries).size !== linked.length)
    throw new Error("Two packages share a native install name");
  const lazyName = installName(
    join(payload, "mock/app.bundle/Contents/Frameworks/libFixtureNative.dylib"),
  );
  if (!/^@rpath\/libFixtureNative\.mock-[0-9a-f]{16}\.dylib$/.test(lazyName))
    throw new Error("A lazy native product kept a shared install name");
  const roles = join(payload, "mock");
  const app = join(roles, "app.bundle");
  const helper = join(roles, "helper.bundle");
  try {
    await access(join(roles, "ExtensionCarrier.app"));
    throw new Error("A package still carries a UI carrier");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
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
  await put(
    "linked-probe.swift",
    `import Darwin
import Foundation
for path in CommandLine.arguments.dropFirst() {
    guard let handle = dlopen(path + "/Contents/MacOS/Runtime", RTLD_NOW | RTLD_LOCAL), let symbol = dlsym(handle, "edith_extension_create") else { exit(1) }
    typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
    guard let pointer = unsafeBitCast(symbol, to: Factory.self)() else { exit(2) }
    let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
    guard let result = object.perform(NSSelectorFromString("execute:"), with: [:] as NSDictionary)?.takeUnretainedValue() as? NSDictionary, let image = result["image"] as? String else { exit(3) }
    let bundle = URL(fileURLWithPath: path).resolvingSymlinksInPath().path + "/Contents/Frameworks/"
    guard URL(fileURLWithPath: image).resolvingSymlinksInPath().path.hasPrefix(bundle) else { exit(4) }
}
`,
  );
  execFileSync("xcrun", [
    "swiftc",
    join(root, "linked-probe.swift"),
    "-o",
    join(root, "linked-probe"),
  ]);
  execFileSync(
    join(root, "linked-probe"),
    linked.map(({ id }) => join(payload, id, "app.bundle")),
  );
  const manifest = JSON.parse(
    await readFile(join(payload, "mock/package.json"), "utf8"),
  );
  if (manifest.id !== "mock")
    throw new Error("Fixture package identity changed");
  const containedManifest = JSON.parse(
    await readFile(join(roles, "package.json"), "utf8"),
  );
  for (const key of ["id", "version", "hostABI", "architecture"])
    if (manifest[key] !== containedManifest[key])
      throw new Error("Contained role package identity changed");
  process.stdout.write(
    `${JSON.stringify({ selectedRoleNativePayloadValidated: true, unselectedRolePayloadAbsent: true, eagerNativeLinkageAbsent: true, relocatedLazyNativeInferenceLoaded: true, strictSignedRolesValidated: true, privateNativeImagesIsolated: true })}\n`,
  );
} finally {
  await rm(root, { recursive: true, force: true });
}
