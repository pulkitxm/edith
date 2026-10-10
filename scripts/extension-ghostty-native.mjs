import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readdir, readFile, rename, writeFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

export const ghosttyBuildInputs = [
  "scripts/build-ghostty.sh",
  "scripts/patches/ghostty-external-io.patch",
  "scripts/extension-ghostty-native.mjs",
  "Extensions/terminal/Native/Package.swift",
];

export function ghosttyNativeInputs(definition) {
  if (definition.nativeProduct !== "GhosttyTerminal") return [];
  if (definition.nativePackage !== "Extensions/terminal/Native")
    throw new Error("Unknown Ghostty native package");
  return [...ghosttyBuildInputs, definition.nativePackage];
}

const vendorPath = "Extensions/terminal/Native/vendor";
const receiptName = ".ghostty-native.json";
const symbols = [
  "ghostty_config_new",
  "ghostty_surface_new",
  "ghostty_surface_free",
  "ghostty_surface_key",
  "ghostty_surface_external_output",
  "ghostty_surface_external_set_termios",
  "ghostty_surface_external_exit",
];
const sha256 = (value) => createHash("sha256").update(value).digest("hex");
const run = (command, args) =>
  execFileSync(command, args, {
    encoding: "utf8",
    maxBuffer: 16 * 1024 * 1024,
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();

export function ghosttyToolchain() {
  const zig = process.env.GHOSTTY_ZIG ?? "zig";
  const zigVersion = run(zig, ["version"]);
  if (zigVersion !== "0.16.0") throw new Error("Ghostty requires Zig 0.16.0");
  return {
    platform: process.platform,
    architecture: process.arch === "arm64" ? "arm64" : "x86_64",
    zig: zigVersion,
    xcode: run("xcodebuild", ["-version"]),
    swift: run("xcrun", ["swift", "--version"]),
    sdk: run("xcrun", ["--sdk", "macosx", "--show-sdk-version"]),
    clang: run("xcrun", ["clang", "--version"]),
  };
}

export async function ghosttyNativeFingerprint(
  root,
  toolchain = ghosttyToolchain(),
) {
  if (toolchain.platform !== "darwin")
    throw new Error("Ghostty requires macOS");
  const digest = createHash("sha256").update(JSON.stringify(toolchain));
  for (const path of ghosttyBuildInputs) {
    const bytes = await readFile(resolve(root, path));
    digest.update(`${path}\0${bytes.length}\0`).update(bytes);
  }
  return digest.digest("hex");
}

async function artifactInventory(root, architecture) {
  const vendor = resolve(root, vendorPath);
  const framework = "GhosttyKit.xcframework";
  const info = JSON.parse(
    run("plutil", [
      "-convert",
      "json",
      "-o",
      "-",
      resolve(vendor, framework, "Info.plist"),
    ]),
  );
  const libraries = info.AvailableLibraries;
  if (!Array.isArray(libraries) || libraries.length !== 1)
    throw new Error("Expected one native Ghostty library");
  const library = libraries[0];
  if (
    library.SupportedPlatform !== "macos" ||
    JSON.stringify(library.SupportedArchitectures) !==
      JSON.stringify([architecture]) ||
    library.LibraryIdentifier !== `macos-${architecture}` ||
    library.LibraryPath !== "libghostty-internal.a" ||
    library.HeadersPath !== "Headers"
  )
    throw new Error("Ghostty archive architecture or layout mismatch");
  const prefix = `${framework}/${library.LibraryIdentifier}`;
  const archive = resolve(vendor, prefix, library.LibraryPath);
  if (run("lipo", ["-archs", archive]) !== architecture)
    throw new Error("Ghostty archive architecture mismatch");
  const exported = new Set(
    run("nm", ["-g", archive])
      .split("\n")
      .flatMap((line) => {
        const match = line.match(/\bT (_ghostty_\w+)$/);
        return match ? [match[1]] : [];
      }),
  );
  for (const symbol of symbols) {
    if (!exported.has(`_${symbol}`))
      throw new Error(`Missing Ghostty symbol ${symbol}`);
  }
  const header = await readFile(
    resolve(vendor, prefix, "Headers/ghostty.h"),
    "utf8",
  );
  for (const name of ["ghostty_external_io_s", ...symbols.slice(4)]) {
    if (!header.includes(name))
      throw new Error(`Missing Ghostty header API ${name}`);
  }
  for (const path of [
    `${prefix}/Headers/module.modulemap`,
    "GhosttyResources/ghostty/shell-integration/zsh/ghostty-integration",
    "GhosttyResources/terminfo/78/xterm-ghostty",
  ]) {
    if (!(await readFile(resolve(vendor, path))).length)
      throw new Error(`Empty Ghostty artifact ${path}`);
  }
  const files = {};
  async function collect(path) {
    for (const entry of (
      await readdir(resolve(vendor, path), { withFileTypes: true })
    ).sort((a, b) => a.name.localeCompare(b.name))) {
      const next = path ? `${path}/${entry.name}` : entry.name;
      if (entry.isSymbolicLink())
        throw new Error("Symlink in Ghostty artifacts");
      if (entry.isDirectory()) await collect(next);
      else if (entry.isFile())
        files[next] = sha256(await readFile(resolve(vendor, next)));
      else throw new Error("Unsupported Ghostty artifact");
    }
  }
  await collect(framework);
  await collect("GhosttyResources");
  return files;
}

export async function verifyGhosttyArtifacts(
  root,
  fingerprint,
  architecture = process.arch === "arm64" ? "arm64" : "x86_64",
) {
  const receipt = JSON.parse(
    await readFile(resolve(root, vendorPath, receiptName), "utf8"),
  );
  if (
    receipt.schema !== 1 ||
    receipt.fingerprint !== fingerprint ||
    receipt.architecture !== architecture
  )
    throw new Error("Stale Ghostty native fingerprint");
  const files = await artifactInventory(root, architecture);
  if (JSON.stringify(files) !== JSON.stringify(receipt.files))
    throw new Error("Ghostty artifact contents differ from verified receipt");
}

export async function recordGhosttyArtifacts(
  root,
  fingerprint,
  architecture = process.arch === "arm64" ? "arm64" : "x86_64",
) {
  const files = await artifactInventory(root, architecture);
  const destination = resolve(root, vendorPath, receiptName);
  const temporary = `${destination}.${process.pid}.tmp`;
  await writeFile(
    temporary,
    `${JSON.stringify({ schema: 1, fingerprint, architecture, files })}\n`,
  );
  await rename(temporary, destination);
}

export async function verifyExtensionNativeDependencies(root, definition) {
  if (!ghosttyNativeInputs(definition).length) return;
  await verifyGhosttyArtifacts(root, await ghosttyNativeFingerprint(root));
}

if (
  process.argv[1] &&
  pathToFileURL(resolve(process.argv[1])).href === import.meta.url
) {
  try {
    const root = process.cwd();
    const fingerprint = await ghosttyNativeFingerprint(root);
    switch (process.argv[2]) {
      case "--fingerprint":
        process.stdout.write(`${fingerprint}\n`);
        break;
      case "--check":
        await verifyGhosttyArtifacts(root, fingerprint);
        break;
      case "--record":
        await recordGhosttyArtifacts(root, fingerprint);
        break;
      default:
        throw new Error("Supply --fingerprint, --check or --record");
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
