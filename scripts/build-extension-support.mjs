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

export function supportModules(scope) {
  if (!/^[A-Za-z][A-Za-z0-9_]{0,160}$/.test(scope))
    throw new Error("Invalid extension support scope");
  return Object.fromEntries(
    [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
      "EdithExtensionArchive",
      "EdithExtensionCommands",
      "ArgumentParser",
      "ArgumentParserToolInfo",
      "ZIPFoundation",
    ].map((name) => [name, `${name}_${scope}`]),
  );
}

export function rewriteSupportImports(source, modules) {
  return source.replace(
    /^(\s*(?:(?:@testable|@_implementationOnly|@_exported|@preconcurrency)\s+)*(?:(?:public|internal|private|fileprivate|package)\s+)?import\s+)(EdithExtensionSupport|EdithExtensionUI|EdithExtensionDocuments|EdithExtensionArchive|EdithExtensionCommands|ArgumentParserToolInfo|ArgumentParser)(?=\s|$)/gm,
    (_, prefix, name) => `${prefix}${modules[name]}`,
  );
}

export function supportProducts(product) {
  const products = {
    EdithExtensionSupport: ["EdithExtensionSupport"],
    EdithExtensionUI: ["EdithExtensionSupport", "EdithExtensionUI"],
    EdithExtensionCommands: [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionCommands",
    ],
    EdithExtensionDocuments: [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionDocuments",
    ],
    EdithExtensionArchive: [
      "EdithExtensionSupport",
      "EdithExtensionUI",
      "EdithExtensionArchive",
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
    );
  return inputs;
}

export function buildExtensionSupport(root, product, scope) {
  const selected = supportProducts(product);
  const buildSystem = selected.includes("EdithExtensionCommands")
    ? "swiftbuild"
    : "native";
  const modules = supportModules(scope);
  const library = Array.isArray(product)
    ? `EdithExtensionBundle_${scope}`
    : modules[product];
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const environment = { ...process.env, DEVELOPER_DIR: developer };
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
  const core = modules.EdithExtensionSupport;
  const ui = modules.EdithExtensionUI;
  const targets = [
    `.target(name: "${core}", swiftSettings: [.swiftLanguageMode(.v5)])`,
  ];
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
              rewriteSupportImports(
                readFileSync(join(sourceRoot, path), "utf8"),
                modules,
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
      process.env.EXTENSION_SWIFT_JOBS ?? "2",
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
