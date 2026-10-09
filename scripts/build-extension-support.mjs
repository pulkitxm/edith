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
    ["EdithExtensionSupport", "EdithExtensionUI"].map((name) => [
      name,
      `${name}_${scope}`,
    ]),
  );
}

export function rewriteSupportImports(source, modules) {
  return source.replace(
    /^(\s*(?:@testable\s+)?import\s+)(EdithExtensionSupport|EdithExtensionUI)(?=\s|$)/gm,
    (_, prefix, name) => `${prefix}${modules[name]}`,
  );
}

export function buildExtensionSupport(root, product, scope) {
  if (!["EdithExtensionSupport", "EdithExtensionUI"].includes(product))
    throw new Error("Unknown extension support product");
  const modules = supportModules(scope);
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const environment = { ...process.env, DEVELOPER_DIR: developer };
  const directory = resolve(root, "local/extension-support", scope);
  const hash = createHash("sha256")
    .update(product)
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
    if (name === "EdithExtensionUI" && product !== name) continue;
    const sourceRoot = resolve(root, "Packages/ExtensionSupport/Sources", name);
    function visit(relative = "") {
      for (const entry of readdirSync(join(sourceRoot, relative), {
        withFileTypes: true,
      }).sort((a, b) => a.name.localeCompare(b.name))) {
        const path = join(relative, entry.name);
        if (entry.isDirectory()) visit(path);
        else if (entry.name.endsWith(".swift")) {
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
      existsSync(join(cached.products, `lib${modules[product]}.a`))
    )
      return { products: cached.products, modules, product: modules[product] };
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
  if (product === "EdithExtensionUI")
    targets.push(
      `.target(name: "${ui}", dependencies: ["${core}"], swiftSettings: [.swiftLanguageMode(.v5)])`,
    );
  writeFileSync(
    join(directory, "Package.swift"),
    `// swift-tools-version:6.0\nimport PackageDescription\nlet package = Package(name: "ExtensionSupport_${scope}", platforms: [.macOS(.v14)], products: [.library(name: "${modules[product]}", type: .static, targets: ["${modules[product]}"])], targets: [${targets.join(", ")}])\n`,
  );
  execFileSync(
    "swift",
    [
      "build",
      "--package-path",
      directory,
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--jobs",
      "2",
      "--product",
      modules[product],
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
      "native",
      "--configuration",
      "release",
      "--show-bin-path",
    ],
    { env: environment, encoding: "utf8" },
  ).trim();
  writeFileSync(receipt, `${JSON.stringify({ fingerprint, products })}\n`);
  return { products, modules, product: modules[product] };
}
