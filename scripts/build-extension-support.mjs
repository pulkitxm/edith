import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { rewriteArgumentParserWarnings } from "./argument-parser-source.mjs";

export function supportModules(scope) {
  if (!/^[A-Za-z][A-Za-z0-9_]{0,160}$/.test(scope))
    throw new Error("Invalid extension support scope");
  return Object.fromEntries(
    [
      "EdithExtensionCore",
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
      "EdithExtensionFiles",
      "EdithExtensionArchive",
      "EdithExtensionAccounts",
      "EdithExtensionCommands",
      "ArgumentParser",
      "ArgumentParserToolInfo",
      "ZIPFoundation",
    ].map((name) => [name, `${name}_${scope}`]),
  );
}

export function rewriteSupportImports(source, modules) {
  return source.replace(
    /^(\s*(?:(?:@testable|@_implementationOnly|@_exported|@preconcurrency)\s+)*(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+)(EdithExtensionCore|EdithExtensionSupport|EdithExtensionUI|EdithExtensionDocuments|EdithExtensionFiles|EdithExtensionArchive|EdithExtensionCommands|EdithExtensionAccounts|ArgumentParserToolInfo|ArgumentParser)(?=\s|$)/gm,
    (_, prefix, name) => `${prefix}${modules[name]}`,
  );
}

export function rewriteArgumentParserSource(source, modules, path) {
  return rewriteSupportImports(
    rewriteArgumentParserWarnings(source, path),
    modules,
  );
}

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
  if (supportProducts(product).includes("EdithExtensionCommands"))
    inputs.push(
      "Packages/ExtensionSupport/Licenses/swift-argument-parser-license.txt",
      "scripts/argument-parser-source.mjs",
    );
  return inputs;
}

export function buildExtensionSupport(
  root,
  product,
  scope,
  sourceEnvironment = process.env,
) {
  const selected = supportProducts(product);
  const buildSystem = selected.includes("EdithExtensionCommands")
    ? "swiftbuild"
    : "native";
  const modules = supportModules(scope);
  const library = Array.isArray(product)
    ? `EdithExtensionBundle_${scope}`
    : modules[product];
  const developer =
    sourceEnvironment.DEVELOPER_DIR ??
    "/Applications/Xcode.app/Contents/Developer";
  const environment = { ...sourceEnvironment, DEVELOPER_DIR: developer };
  const directory = resolve(root, "local/extension-support", scope);
  const hash = createHash("sha256")
    .update(Array.isArray(product) ? JSON.stringify(selected) : product)
    .update(scope)
    .update(developer);
  hash.update(
    execFileSync("xcrun", ["swiftc", "--version"], { env: environment }),
  );
  hash.update(
    execFileSync("xcrun", ["--sdk", "macosx", "--show-sdk-version"], {
      env: environment,
    }),
  );
  hash.update(
    readFileSync(resolve(root, "scripts/build-extension-support.mjs")),
  );
  if (selected.includes("EdithExtensionCommands"))
    hash.update(
      readFileSync(resolve(root, "scripts/argument-parser-source.mjs")),
    );
  const sources = [];
  for (const [name, module] of Object.entries(modules)) {
    if (!selected.includes(name)) continue;
    const sourceRoot = resolve(root, "Packages/ExtensionSupport/Sources", name);
    function visit(relative = "") {
      for (const entry of readdirSync(join(sourceRoot, relative), {
        withFileTypes: true,
      }).sort((a, b) => a.name.localeCompare(b.name))) {
        const path = join(relative, entry.name);
        if (entry.isDirectory()) visit(path);
        else if (!entry.name.endsWith(".swift")) {
          hash
            .update(`${name}/${path}\0`)
            .update(readFileSync(join(sourceRoot, path)));
        } else {
          const source = readFileSync(join(sourceRoot, path), "utf8");
          hash.update(`${name}/${path}\0`).update(source);
          sources.push({
            module,
            path,
            source: rewriteSupportImports(source, modules),
          });
        }
      }
    }
    visit();
  }
  const fingerprint = hash.digest("hex");
  const receipt = join(directory, "build.json");
  if (existsSync(receipt)) {
    const cached = JSON.parse(readFileSync(receipt, "utf8"));
    if (
      cached.fingerprint === fingerprint &&
      existsSync(join(cached.products, `lib${library}.a`))
    )
      return { products: cached.products, modules, product: library };
  }
  rmSync(join(directory, "Sources"), { recursive: true, force: true });
  mkdirSync(directory, { recursive: true });
  for (const { module, path, source } of sources) {
    const target = join(directory, "Sources", module, path);
    mkdirSync(resolve(target, ".."), { recursive: true });
    writeFileSync(target, source);
  }
  const core = modules.EdithExtensionCore;
  const ui = modules.EdithExtensionUI;
  const targets = [
    `.target(name: "${core}", swiftSettings: [.swiftLanguageMode(.v5)])`,
  ];
  if (selected.includes("EdithExtensionSupport"))
    targets.push(
      `.target(name: "${modules.EdithExtensionSupport}", dependencies: ["${core}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  if (selected.includes("EdithExtensionUI"))
    targets.push(
      `.target(name: "${ui}", dependencies: ["${core}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  if (selected.includes("EdithExtensionDocuments")) {
    const documents = modules.EdithExtensionDocuments;
    const resourceRoot = resolve(
      root,
      "Packages/ExtensionSupport/Sources/EdithExtensionDocuments/Resources",
    );
    const targetResources = join(directory, "Sources", documents, "Resources");
    mkdirSync(targetResources, { recursive: true });
    for (const resource of readdirSync(resourceRoot)) {
      writeFileSync(
        join(targetResources, resource),
        readFileSync(join(resourceRoot, resource)),
      );
    }
    targets.push(
      `.target(name: "${documents}", dependencies: ["${ui}"], resources: [.process("Resources")], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  }
  if (selected.includes("EdithExtensionFiles"))
    targets.push(
      `.target(name: "${modules.EdithExtensionFiles}", dependencies: ["${ui}", "${modules.EdithExtensionDocuments}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  if (selected.includes("EdithExtensionAccounts"))
    targets.push(
      `.target(name: "${modules.EdithExtensionAccounts}", dependencies: ["${core}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  const packageDependencies = [];
  let parserDependency;
  if (selected.includes("EdithExtensionArchive"))
    packageDependencies.push(
      '.package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")',
    );
  if (selected.includes("EdithExtensionCommands")) {
    parserDependency =
      '.package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")';
    targets.push(
      `.target(name: "${modules.EdithExtensionCommands}", dependencies: ["${core}", "${ui}", "${modules.ArgumentParser}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  }
  if (selected.includes("EdithExtensionArchive"))
    targets.push(
      `.target(name: "${modules.EdithExtensionArchive}", dependencies: ["${ui}", .product(name: "ZIPFoundation", package: "ZIPFoundation", moduleAliases: ["ZIPFoundation": "${modules.ZIPFoundation}"])], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  const manifest = (dependencies, generatedTargets) =>
    `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "ExtensionSupport_${scope}", platforms: [.macOS(.v14)], products: [.library(name: "${library}", type: .static, targets: [${selected.map((name) => `"${modules[name]}"`).join(", ")}])], dependencies: [${dependencies.join(", ")}], targets: [${generatedTargets.join(", ")}])\n`;
  if (parserDependency) {
    writeFileSync(
      join(directory, "Package.swift"),
      `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "ExtensionSupport_${scope}", dependencies: [${parserDependency}])\n`,
    );
    execFileSync("swift", ["package", "--package-path", directory, "resolve"], {
      env: environment,
      stdio: "inherit",
    });
    const parserRoot = join(
      directory,
      ".build/checkouts/swift-argument-parser/Sources",
    );
    for (const name of ["ArgumentParserToolInfo", "ArgumentParser"]) {
      const sourceRoot = join(parserRoot, name);
      const targetRoot = join(directory, "Sources", modules[name]);
      function copy(relative = "") {
        for (const entry of readdirSync(join(sourceRoot, relative), {
          withFileTypes: true,
        })) {
          const path = join(relative, entry.name);
          if (entry.isDirectory()) copy(path);
          else if (entry.name.endsWith(".swift")) {
            const target = join(targetRoot, path);
            mkdirSync(resolve(target, ".."), { recursive: true });
            writeFileSync(
              target,
              rewriteArgumentParserSource(
                readFileSync(join(sourceRoot, path), "utf8"),
                modules,
                name === "ArgumentParser" ? path : undefined,
              ),
            );
          }
        }
      }
      copy();
      const dependencies =
        name === "ArgumentParser" ? [modules.ArgumentParserToolInfo] : [];
      targets.push(
        `.target(name: "${modules[name]}", dependencies: [${dependencies.map((module) => `"${module}"`).join(", ")}], swiftSettings: [.swiftLanguageMode(.v6)])`,
      );
    }
  }
  writeFileSync(
    join(directory, "Package.swift"),
    manifest(packageDependencies, targets),
  );
  execFileSync(
    "swift",
    [
      "build",
      ...(selected.includes("EdithExtensionCommands")
        ? ["--disable-build-manifest-caching"]
        : []),
      "--package-path",
      directory,
      "--build-system",
      buildSystem,
      "--configuration",
      "release",
      "--jobs",
      environment.EXTENSION_SWIFT_JOBS ?? "2",
      "--product",
      library,
      "-Xswiftc",
      "-plugin-path",
      "-Xswiftc",
      `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
    ],
    { env: environment, stdio: "inherit" },
  );
  const products = execFileSync(
    "swift",
    [
      "build",
      "--package-path",
      directory,
      "--build-system",
      buildSystem,
      "--configuration",
      "release",
      "--show-bin-path",
    ],
    { env: environment, encoding: "utf8" },
  ).trim();
  writeFileSync(receipt, `${JSON.stringify({ fingerprint, products })}\n`);
  return { products, modules, product: library };
}

export function contextModule(scope) {
  return supportModules(scope).EdithExtensionSupport;
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
  execFileSync("python3", ["-I", "-B", "scripts/prepare-argument-parser.py", packagePath], {
    cwd: root,
    env: environment,
    stdio: "inherit",
  });
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
  return { products, modules: resolve(products, "Modules"), library: "EdithExtensionKit" };
}

export function buildExtensionContext(root, kit, scope, directory, sourceEnvironment = process.env) {
  const module = contextModule(scope);
  const environment = {
    ...sourceEnvironment,
    DEVELOPER_DIR:
      sourceEnvironment.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer",
  };
  const sourceRoot = resolve(root, "Packages/ExtensionSupport/Sources/EdithExtensionSupport");
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
