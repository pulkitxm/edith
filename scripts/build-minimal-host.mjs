import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import {
  copyFile,
  mkdir,
  readdir,
  readFile,
  rm,
  stat,
  writeFile,
} from "node:fs/promises";
import { basename, join, resolve } from "node:path";
import { extensionUIExtensionPoint } from "./build-extension-ui-carrier.mjs";

const root = process.cwd();
const packageDirectory = resolve(root, "Packages/EdithHost");
const destination = resolve(root, "local/minimal-host/Edith.app");
const developer =
  process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
const environment = { ...process.env, DEVELOPER_DIR: developer };
const swift = [
  "build",
  "--package-path",
  packageDirectory,
  "--build-system",
  "native",
  "--configuration",
  "release",
  "--jobs",
  process.env.EXTENSION_SWIFT_JOBS ?? "2",
  "--product",
  "EdithHost",
  "-Xswiftc",
  "-Osize",
  "-Xswiftc",
  "-plugin-path",
  "-Xswiftc",
  `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
];
execFileSync("swift", swift, { env: environment, stdio: "inherit" });
const products = execFileSync(
  "swift",
  [
    "build",
    "--package-path",
    packageDirectory,
    "--build-system",
    "native",
    "--configuration",
    "release",
    "--show-bin-path",
  ],
  { env: environment, encoding: "utf8" },
).trim();
await rm(destination, { recursive: true, force: true });
const contents = join(destination, "Contents");
const executable = join(contents, "MacOS/Edith");
await mkdir(join(contents, "MacOS"), { recursive: true });
await mkdir(join(contents, "Frameworks"), { recursive: true });
await mkdir(join(contents, "Resources"), { recursive: true });
await copyFile(join(products, "EdithHost"), executable);
const sparkle = join(contents, "Frameworks/Sparkle.framework");
execFileSync("/bin/cp", ["-RL", join(products, "Sparkle.framework"), sparkle]);
await rm(join(sparkle, "Versions"), { recursive: true, force: true });
async function prepareFramework(directory) {
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (["Headers", "PrivateHeaders", "Modules"].includes(entry.name)) {
      await rm(path, { recursive: true, force: true });
      continue;
    }
    if (entry.isDirectory()) await prepareFramework(path);
    else if (entry.isFile()) {
      const kind = execFileSync("file", ["-b", path], {
        encoding: "utf8",
      });
      if (!kind.includes("Mach-O")) continue;
      if (kind.includes("universal binary")) {
        const thin = `${path}.arm64`;
        execFileSync("lipo", [path, "-thin", "arm64", "-output", thin]);
        execFileSync("mv", [thin, path]);
      }
      const links = execFileSync("otool", ["-L", path], {
        encoding: "utf8",
      });
      for (const line of links.split("\n").slice(1)) {
        const dependency = line.trim().split(" ")[0];
        if (dependency.endsWith("/Sparkle.framework/Versions/B/Sparkle")) {
          execFileSync("install_name_tool", [
            "-change",
            dependency,
            "@rpath/Sparkle.framework/Sparkle",
            path,
          ]);
        }
      }
      if (entry.name === "Sparkle")
        execFileSync("install_name_tool", [
          "-id",
          "@rpath/Sparkle.framework/Sparkle",
          path,
        ]);
      execFileSync("codesign", ["--force", "--sign", "-", path]);
    }
  }
  if (["framework", "xpc", "app"].includes(directory.split(".").at(-1)))
    execFileSync("codesign", ["--force", "--sign", "-", directory]);
}
await prepareFramework(sparkle);
await copyFile(
  resolve(root, "Resources/AppIcon.icns"),
  join(contents, "Resources/AppIcon.icns"),
);
await copyFile(
  join(packageDirectory, "Sources/EdithHostCore/Resources/index.json"),
  join(contents, "Resources/index.json"),
);
await mkdir(join(contents, "Library/LaunchDaemons"), { recursive: true });
await writeFile(
  join(
    contents,
    "Library/LaunchDaemons/com.pulkit.edith.extensions.carrier.v1.plist",
  ),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>Label</key><string>com.pulkit.edith.extensions.carrier.v1</string><key>BundleProgram</key><string>Contents/MacOS/Edith</string><key>ProgramArguments</key><array><string>Edith</string><string>--extension-carrier</string></array><key>MachServices</key><dict><key>com.pulkit.edith.extensions.carrier.v1</key><true/></dict></dict></plist>
`,
);
const identity = `com.pulkit.edith.dev.${basename(root)}`;
const plist = {
  CFBundleIdentifier: identity,
  CFBundleName: `Edith (${basename(root)})`,
  CFBundleDisplayName: `Edith (${basename(root)})`,
  CFBundleExecutable: "Edith",
  CFBundleIconFile: "AppIcon",
  CFBundlePackageType: "APPL",
  CFBundleShortVersionString: "0.1.0",
  CFBundleVersion: "1",
  NSPrincipalClass: "NSApplication",
  NSCalendarsFullAccessUsageDescription:
    "Show your upcoming events in the Calendar extension.",
  NSCameraUsageDescription:
    "Show the optional camera preview in the Notch extension.",
  NSMicrophoneUsageDescription:
    "Record optional microphone audio in Screen Recorder and Companion extensions.",
  NSAppleEventsUsageDescription:
    "Control playback in music apps you select in the Music extension.",
  LSMinimumSystemVersion: "14.0",
  SUFeedURL:
    "https://github.com/pulkitxm/edith/releases/latest/download/appcast.xml",
  SUPublicEDKey: "qz/e9EfPlNiHqJC9JA9RazcXGgnH2wxwpS+uw+x9qBM=",
  SUEnableAutomaticChecks: true,
  SUScheduledCheckInterval: 86400,
};
execFileSync("python3", [
  "-c",
  "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
  JSON.stringify(plist),
  join(contents, "Info.plist"),
]);
await mkdir(join(contents, "Extensions"), { recursive: true });
execFileSync("python3", [
  "-c",
  "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
  JSON.stringify(extensionUIExtensionPoint(identity)),
  join(contents, "Extensions/ExtensionUI.appextensionpoints"),
]);
const linked = execFileSync("otool", ["-L", executable], { encoding: "utf8" });
for (const line of linked.split("\n").slice(1)) {
  const dependency = line.trim().split(" ")[0];
  if (dependency.endsWith("/Sparkle.framework/Versions/B/Sparkle")) {
    execFileSync("install_name_tool", [
      "-change",
      dependency,
      "@rpath/Sparkle.framework/Sparkle",
      executable,
    ]);
  }
}
execFileSync("install_name_tool", [
  "-add_rpath",
  "@executable_path/../Frameworks",
  executable,
]);
execFileSync("install_name_tool", [
  "-add_rpath",
  "@executable_path/../../../../Frameworks",
  executable,
]);
for (const file of [executable]) {
  const commands = execFileSync("otool", ["-l", file], { encoding: "utf8" });
  for (const match of commands.matchAll(
    /cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (\S+) \(offset/g,
  )) {
    if (
      match[1].startsWith("/") &&
      !match[1].startsWith("/usr/") &&
      !match[1].startsWith("/System/")
    )
      execFileSync("install_name_tool", ["-delete_rpath", match[1], file]);
  }
  execFileSync("strip", ["-rSTx", file]);
  execFileSync("codesign", ["--force", "--sign", "-", file], {
    stdio: "inherit",
  });
}
execFileSync("codesign", ["--force", "--sign", "-", destination], {
  stdio: "inherit",
});
execFileSync("codesign", ["--verify", "--deep", "--strict", destination], {
  stdio: "inherit",
});
const closure = execFileSync("otool", ["-L", executable], {
  encoding: "utf8",
});
for (const name of [
  "EdithShared",
  "EdithKit",
  "MeetingVoice",
  "Ghostty",
  "EdithStudio",
  "NIO",
  "GRDB",
  "Highlighter",
]) {
  assert(
    !closure.includes(name),
    `Feature dependency leaked into the host: ${name}`,
  );
}
const symbols = execFileSync("nm", ["-g", executable], {
  encoding: "utf8",
});
for (const name of [
  "HerdrStore",
  "MusicPlayerEngine",
  "MeetingVoice",
  "DatabasePage",
  "StudioPage",
  "QuinjetPage",
]) {
  assert(
    !symbols.includes(name),
    `Feature implementation leaked into the host: ${name}`,
  );
}
async function installedBytes(directory) {
  let total = 0;
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) total += await installedBytes(path);
    else if (entry.isFile()) total += (await stat(path)).size;
  }
  return total;
}
const bytes = await installedBytes(destination);
assert(
  bytes < 5_000_000,
  `The minimal host exceeds its 5 MB size limit: ${bytes}`,
);
const index = JSON.parse(
  await readFile(join(contents, "Resources/index.json"), "utf8"),
);
assert(index.length >= 35);
process.stdout.write(
  `${JSON.stringify({ app: "Edith.app", installedBytes: bytes, extensionPayloadBytes: 0, indexedExtensions: index.length, signature: "verified", dependencyBoundary: "passed" }, null, 2)}\n`,
);
