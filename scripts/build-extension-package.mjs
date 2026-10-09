import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { copyFile, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { buildExtensionSupport } from "./build-extension-support.mjs";
import { writeHostABI } from "./extension-host-abi.mjs";
import { buildHostInterfaces } from "./extension-host-build.mjs";
import { extensionFingerprint } from "./extension-release-plan.mjs";

export async function buildExtensionPackage({
  root = process.cwd(),
  id,
  output,
  development = false,
  version,
  tagOverride,
}) {
  await writeHostABI(root);
  const definitions = JSON.parse(
    await readFile(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const definition = definitions.find((entry) => entry.id === id);
  if (!definition) throw new Error(`Unknown extension ${id}`);
  if (definition.contractVersion === 1 && definition.usesHostFramework)
    throw new Error(
      "Worker extensions must not depend on the legacy host framework",
    );
  const releaseVersion = version ?? definition.version;
  const identity = process.env.EXTENSION_SIGN_IDENTITY;
  if (!development && (!identity || identity === "-"))
    throw new Error("A release signing identity is required");
  const fingerprint = await extensionFingerprint(root, definition, definitions);
  const tag = tagOverride ?? `extensions/${id}/${fingerprint.slice(0, 20)}`;
  const target = resolve(output ?? resolve(root, "dist/extensions"));
  const staging = resolve(target, ".staging", id);
  await rm(staging, { recursive: true, force: true });
  await mkdir(staging, { recursive: true });
  const payload = resolve(staging, id);
  await mkdir(payload);
  const hostProducts = definition.usesHostFramework
    ? (process.env.EXTENSION_HOST_PRODUCTS ?? (await buildHostInterfaces(root)))
    : undefined;
  const supportProducts = definition.supportProduct
    ? buildExtensionSupport(root, definition.supportProduct)
    : undefined;
  if (definition.nativePackage) {
    execFileSync(
      "swift",
      [
        "build",
        "--package-path",
        resolve(root, definition.nativePackage),
        "--build-system",
        "native",
        "--configuration",
        "release",
        "--jobs",
        "2",
        "--force-resolved-versions",
        "--product",
        definition.nativeProduct,
      ],
      { stdio: "inherit" },
    );
  }
  for (const [role, sources] of Object.entries(definition.roles)) {
    if (!["app", "helper", "agent", "cli"].includes(role))
      throw new Error(`Unknown host role ${role}`);
    const bundle = resolve(payload, `${role}.bundle`);
    const contents = resolve(bundle, "Contents");
    await mkdir(resolve(contents, "MacOS"), { recursive: true });
    const executable = resolve(contents, "MacOS", "Runtime");
    const nativeFlags = [];
    if (definition.nativePackage) {
      const libraryName = `lib${definition.nativeProduct}.dylib`;
      const frameworks = resolve(contents, "Frameworks");
      await mkdir(frameworks);
      const resources = resolve(contents, "Resources");
      await mkdir(resources);
      await copyFile(
        resolve(
          root,
          definition.nativePackage,
          ".build/artifacts/onnxruntime-swift-package-manager/onnxruntime/LICENSE",
        ),
        resolve(resources, "onnxruntime-LICENSE"),
      );
      const library = resolve(frameworks, libraryName);
      await copyFile(
        resolve(root, definition.nativePackage, ".build/release", libraryName),
        library,
      );
      execFileSync("install_name_tool", [
        "-id",
        `@rpath/${libraryName}`,
        library,
      ]);
      execFileSync("strip", ["-rSTx", library]);
      execFileSync(
        "codesign",
        [
          "--force",
          "--sign",
          development ? "-" : identity,
          ...(development ? [] : ["--options", "runtime", "--timestamp"]),
          library,
        ],
        { stdio: "inherit" },
      );
      nativeFlags.push(
        "-L",
        frameworks,
        `-l${definition.nativeProduct}`,
        "-Xlinker",
        "-rpath",
        "-Xlinker",
        "@loader_path/../Frameworks",
      );
    }
    execFileSync(
      "xcrun",
      [
        "swiftc",
        "-emit-library",
        "-parse-as-library",
        "-Osize",
        "-whole-module-optimization",
        "-module-name",
        `EdithExtension_${id}_${role}`,
        "-target",
        `arm64-apple-macos${definition.minimumSystemVersion}.0`,
        ...sources.map((path) => resolve(root, path)),
        ...(supportProducts
          ? [
              "-swift-version",
              "5",
              "-I",
              resolve(supportProducts, "Modules"),
              "-L",
              supportProducts,
              `-l${definition.supportProduct}`,
              "-Xlinker",
              "-dead_strip",
            ]
          : []),
        ...(hostProducts
          ? [
              "-swift-version",
              "5",
              "-I",
              resolve(hostProducts, "Modules"),
              "-L",
              hostProducts,
              "-lEdithShared",
            ]
          : []),
        ...nativeFlags,
        "-Xlinker",
        "-install_name",
        "-Xlinker",
        `@rpath/EdithExtension_${id}_${role}`,
        ...(definition.contractVersion === 1
          ? [
              "-Xlinker",
              "-dead_strip",
              "-Xlinker",
              "-exported_symbol",
              "-Xlinker",
              "_edith_extension_create",
            ]
          : []),
        "-o",
        executable,
      ],
      { stdio: "inherit" },
    );
    if (hostProducts) {
      const dependencies = execFileSync("otool", ["-L", executable], {
        encoding: "utf8",
      });
      const shared = dependencies
        .split("\n")
        .map((line) => line.trim().split(" ")[0])
        .find((path) => path.endsWith("/libEdithShared.dylib"));
      if (!shared) throw new Error("Missing host framework linkage");
      execFileSync("install_name_tool", [
        "-change",
        shared,
        "@rpath/EdithShared.framework/Versions/A/EdithShared",
        executable,
      ]);
    }
    const info = {
      CFBundleIdentifier: `com.pulkit.edith.extensions.${id}.${role}`,
      CFBundleName: id,
      CFBundlePackageType: "BNDL",
      CFBundleExecutable: "Runtime",
      CFBundleShortVersionString: releaseVersion,
      CFBundleVersion: releaseVersion,
      EdithHostABI: definition.hostABI,
    };
    if (definition.contractVersion === 1) {
      const linkage = execFileSync("otool", ["-L", executable], {
        encoding: "utf8",
      });
      if (
        linkage.includes("EdithShared.framework") ||
        linkage.includes("libEdithShared.dylib")
      )
        throw new Error("Legacy host code leaked into a worker package");
      for (const line of linkage.split("\n").slice(1)) {
        const dependency = line.trim().split(" ")[0];
        if (
          dependency.startsWith("/") &&
          !dependency.startsWith("/System/") &&
          !dependency.startsWith("/usr/")
        )
          throw new Error("A worker package links a private build path");
      }
    }
    const infoJSON = resolve(staging, `${role}-info.json`);
    await writeFile(infoJSON, JSON.stringify(info));
    execFileSync("python3", [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.load(open(sys.argv[1])),open(sys.argv[2],'wb'),fmt=plistlib.FMT_BINARY)",
      infoJSON,
      resolve(contents, "Info.plist"),
    ]);
    execFileSync("strip", ["-rSTx", executable]);
    const symbols = execFileSync("nm", ["-g", executable], {
      encoding: "utf8",
    });
    if (!symbols.includes(" T _edith_extension_create"))
      throw new Error("Extension entry point was not exported");
    const flags = development ? [] : ["--options", "runtime", "--timestamp"];
    execFileSync(
      "codesign",
      ["--force", "--sign", development ? "-" : identity, ...flags, bundle],
      { stdio: "inherit" },
    );
    execFileSync("codesign", ["--verify", "--strict", bundle], {
      stdio: "inherit",
    });
  }
  const payloadManifest = {
    id,
    version: releaseVersion,
    hostABI: definition.hostABI,
    architecture: "arm64",
    dependencies: definition.dependencies,
  };
  await writeFile(
    resolve(payload, "package.json"),
    JSON.stringify(payloadManifest),
  );
  const archive = resolve(target, `${id}.zip`);
  const summary = JSON.parse(
    execFileSync(
      "python3",
      [
        "-c",
        "import json,pathlib,sys,zipfile; root=pathlib.Path(sys.argv[1]); files=sorted(p for p in root.rglob('*') if p.is_file()); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED,compresslevel=9); [(z.write(p,p.relative_to(root.parent))) for p in files]; z.close(); print(json.dumps({'installedBytes':sum(p.stat().st_size for p in files)}))",
        payload,
        archive,
      ],
      { encoding: "utf8" },
    ),
  );
  const bytes = await readFile(archive);
  const repository = process.env.GITHUB_REPOSITORY ?? "pulkitxm/edith";
  const packageRecord = {
    ...payloadManifest,
    minimumSystemVersion: definition.minimumSystemVersion,
    downloadURL: `https://github.com/${repository}/releases/download/${encodeURIComponent(tag)}/${id}.zip`,
    sha256: createHash("sha256").update(bytes).digest("hex"),
    downloadBytes: bytes.length,
    installedBytes: summary.installedBytes,
    sourceFingerprint: fingerprint,
  };
  await writeFile(
    resolve(target, `${id}.json`),
    `${JSON.stringify(packageRecord, null, 2)}\n`,
  );
  await writeFile(
    resolve(target, `${id}.zip.sha256`),
    `${packageRecord.sha256}  ${id}.zip\n`,
  );
  await rm(staging, { recursive: true, force: true });
  return { ...packageRecord, fingerprint, tag };
}

if (import.meta.main) {
  const id = process.argv[2];
  if (!id) throw new Error("Supply an extension id");
  const result = await buildExtensionPackage({
    id,
    version: process.env.EXTENSION_VERSION,
    tagOverride: process.env.EXTENSION_RELEASE_TAG,
    output: process.env.EXTENSION_OUTPUT,
    development: process.argv.includes("--development"),
  });
  process.stdout.write(`${JSON.stringify(result)}\n`);
}
