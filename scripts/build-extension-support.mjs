import { execFileSync } from "node:child_process";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";

export function supportProducts(product) {
  const products = {
    EdithExtensionCore: ["EdithExtensionCore"],
    EdithExtensionSupport: ["EdithExtensionCore", "EdithExtensionSupport"],
    EdithExtensionUI: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
    ],
    EdithExtensionCommands: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionCommands",
    ],
    EdithExtensionDocuments: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
    ],
    EdithExtensionFiles: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
      "EdithExtensionFiles",
    ],
    EdithExtensionArchive: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionArchive",
    ],
    EdithExtensionAccounts: [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionAccounts",
    ],
  };
  const requested = Array.isArray(product) ? product : [product];
  if (
    !requested.length ||
    requested.length > Object.keys(products).length ||
    requested.some(
      (name) => typeof name !== "string" || !Object.hasOwn(products, name),
    )
  )
    throw new Error("Unknown extension support product");
  const selected = new Set(requested.flatMap((name) => products[name]));
  return Object.keys(products).filter((name) => selected.has(name));
}

export function supportSourceInputs(product) {
  const inputs = supportProducts(product).map(
    (name) => `Packages/ExtensionSupport/Sources/${name}`,
  );
  if (supportProducts(product).includes("EdithExtensionUI"))
    inputs.push(
      "Packages/EdithIcons/Package.swift",
      "Packages/EdithIcons/Sources",
    );
  if (supportProducts(product).includes("EdithExtensionCommands"))
    inputs.push(
      "Packages/ExtensionSupport/Licenses/swift-argument-parser-license.txt",
      "scripts/argument-parser-source.mjs",
    );
  return inputs;
}

export function contextModule(scope) {
  if (!/^[A-Za-z][A-Za-z0-9_]{0,160}$/.test(scope))
    throw new Error("Invalid extension support scope");
  return `EdithExtensionSupport_${scope}`;
}

export function rewriteContextImports(source, scope) {
  const module = contextModule(scope);
  return source.replace(
    /^(\s*(?:(?:@testable|@_implementationOnly|@_exported|@preconcurrency)\s+)*(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+)EdithExtensionSupport(?=\s|$)/gm,
    (_, prefix) => `${prefix}${module}`,
  );
}

export function buildExtensionKit(root, sourceEnvironment = process.env) {
  const developer =
    sourceEnvironment.DEVELOPER_DIR ??
    "/Applications/Xcode.app/Contents/Developer";
  const environment = { ...sourceEnvironment, DEVELOPER_DIR: developer };
  const packagePath = resolve(root, "Packages/ExtensionSupport");
  execFileSync(
    "python3",
    ["-I", "-B", "scripts/prepare-argument-parser.py", packagePath],
    {
      cwd: root,
      env: environment,
      stdio: "inherit",
    },
  );
  const common = [
    "--package-path",
    packagePath,
    "--build-system",
    "native",
    "--configuration",
    "release",
  ];
  execFileSync(
    "swift",
    [
      "build",
      ...common,
      "--jobs",
      environment.EXTENSION_SWIFT_JOBS ?? "2",
      "--product",
      "EdithExtensionKit",
      "-Xswiftc",
      "-Osize",
      "-Xswiftc",
      "-plugin-path",
      "-Xswiftc",
      `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
    ],
    { env: environment, stdio: "inherit" },
  );
  const products = execFileSync(
    "swift",
    ["build", ...common, "--show-bin-path"],
    { env: environment, encoding: "utf8" },
  ).trim();
  return {
    products,
    modules: resolve(products, "Modules"),
    library: "EdithExtensionKit",
  };
}

export function buildExtensionContext(
  root,
  kit,
  scope,
  directory,
  sourceEnvironment = process.env,
) {
  const module = contextModule(scope);
  const environment = {
    ...sourceEnvironment,
    DEVELOPER_DIR:
      sourceEnvironment.DEVELOPER_DIR ??
      "/Applications/Xcode.app/Contents/Developer",
  };
  const sourceRoot = resolve(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionSupport",
  );
  const sources = resolve(directory, "sources");
  rmSync(directory, { recursive: true, force: true });
  mkdirSync(sources, { recursive: true });
  const files = readdirSync(sourceRoot)
    .filter((name) => name.endsWith(".swift"))
    .sort()
    .map((name) => {
      const target = join(sources, name);
      writeFileSync(target, readFileSync(join(sourceRoot, name), "utf8"));
      return target;
    });
  const objects = resolve(directory, "objects");
  mkdirSync(objects, { recursive: true });
  execFileSync(
    "xcrun",
    [
      "swiftc",
      "-parse-as-library",
      "-swift-version",
      "5",
      "-Osize",
      "-whole-module-optimization",
      "-module-name",
      module,
      "-target",
      "arm64-apple-macos14.0",
      "-I",
      kit.modules,
      "-I",
      kit.products,
      "-emit-module",
      "-emit-module-path",
      resolve(directory, `${module}.swiftmodule`),
      "-c",
      ...files,
      "-o",
      resolve(objects, `${module}.o`),
    ],
    { env: environment, stdio: "inherit" },
  );
  execFileSync("libtool", [
    "-static",
    "-o",
    resolve(directory, `lib${module}.a`),
    resolve(objects, `${module}.o`),
  ]);
  return { directory, module };
}

export function prepareNativeContext(root, scope) {
  const module = contextModule(scope);
  const directory = resolve(root, "local/extension-support", scope);
  const sourceRoot = resolve(
    root,
    "Packages/ExtensionSupport/Sources/EdithExtensionSupport",
  );
  const target = join(directory, "Sources", module);
  rmSync(join(directory, "Sources"), { recursive: true, force: true });
  mkdirSync(target, { recursive: true });
  for (const name of readdirSync(sourceRoot)
    .filter((entry) => entry.endsWith(".swift"))
    .sort())
    writeFileSync(
      join(target, name),
      readFileSync(join(sourceRoot, name), "utf8"),
    );
  const kit = resolve(root, "Packages/ExtensionSupport");
  const manifest = `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "${scope}", platforms: [.macOS(.v14)], products: [.library(name: "${module}", type: .static, targets: ["${module}"])], dependencies: [.package(name: "ExtensionSupport", path: ${JSON.stringify(kit)})], targets: [.target(name: "${module}", dependencies: [.product(name: "EdithExtensionKit", package: "ExtensionSupport")], swiftSettings: [.swiftLanguageMode(.v5)])])\n`;
  const path = join(directory, "Package.swift");
  if (!existsSync(path) || readFileSync(path, "utf8") !== manifest)
    writeFileSync(path, manifest);
  return { directory, module };
}
