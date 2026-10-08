import { execFileSync } from "node:child_process";
import { access, cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { writeHostABI } from "./extension-host-abi.mjs";

export async function buildHostInterfaces(root = process.cwd()) {
  const directory = resolve(root, "build/extension-host");
  const abi = await writeHostABI(root);
  const marker = resolve(directory, "host-abi");
  const products = resolve(directory, ".build/release");
  await rm(resolve(directory, "Presenter"), { recursive: true, force: true });
  await cp(
    resolve(root, "Extensions/presenter/Helper"),
    resolve(directory, "Presenter"),
    { recursive: true },
  );
  await rm(resolve(directory, "PresenterTests"), {
    recursive: true,
    force: true,
  });
  await cp(
    resolve(root, "Extensions/presenter/Tests"),
    resolve(directory, "PresenterTests"),
    { recursive: true },
  );
  try {
    if ((await readFile(marker, "utf8")) === abi) {
      await access(resolve(products, "Modules/EdithKit.swiftmodule"));
      return products;
    }
  } catch {}
  await rm(resolve(directory, "Sources"), { recursive: true, force: true });
  await mkdir(resolve(directory, "Sources"), { recursive: true });
  for (const module of [
    "EdithCore",
    "EdithKit",
    "EdithCameraSupport",
    "EdithLidAwakeSupport",
    "EdithShared",
  ])
    await cp(
      resolve(root, "Packages/Edith/Sources", module),
      resolve(directory, "Sources", module),
      { recursive: true, force: true },
    );
  const sdk = resolve(root, "Packages/ExtensionMarketplace");
  await writeFile(
    resolve(directory, "Package.swift"),
    `// swift-tools-version:6.0
import PackageDescription
let package = Package(
    name: "ExtensionHost",
    platforms: [.macOS(.v14)],
    products: [.library(name: "EdithShared", type: .dynamic, targets: ["EdithShared"])],
    dependencies: [.package(path: ${JSON.stringify(sdk)}), .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.19")],
    targets: [
        .target(name: "EdithCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithCameraSupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithLidAwakeSupport", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithKit", dependencies: ["EdithCore", "EdithLidAwakeSupport", "EdithCameraSupport", .product(name: "ExtensionMarketplace", package: "ExtensionMarketplace"), .product(name: "ZIPFoundation", package: "ZIPFoundation")], resources: [.process("Resources"), .copy("ChromeExtension"), .copy("LaTeXEditor")], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "EdithShared", dependencies: ["EdithKit", "EdithCore", "EdithCameraSupport", "EdithLidAwakeSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "PresenterExtension", dependencies: ["EdithKit"], path: "Presenter", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "PresenterExtensionTests", dependencies: ["PresenterExtension", "EdithKit"], path: "PresenterTests", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
`,
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
      "EdithShared",
      "-Xswiftc",
      "-plugin-path",
      "-Xswiftc",
      `${process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer"}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
    ],
    { stdio: "inherit" },
  );
  await writeFile(marker, abi);
  return products;
}

if (import.meta.main) await buildHostInterfaces();
