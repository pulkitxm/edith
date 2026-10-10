import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const required = ["Sparkle.framework"];

function verify({ missing, extra, pointIdentifier } = {}) {
  const root = mkdtempSync(join(tmpdir(), "extension-bundle-layout-"));
  try {
    const app = join(root, "Edith.app");
    const contents = join(app, "Contents");
    for (const path of ["MacOS", "Frameworks", "Resources"])
      mkdirSync(join(contents, path), { recursive: true });
    writeFileSync(join(contents, "MacOS/Edith"), "synthetic host");
    for (const name of required.filter((name) => name !== missing)) {
      if (name.endsWith(".framework"))
        mkdirSync(join(contents, "Frameworks", name));
      else
        writeFileSync(join(contents, "Frameworks", name), "synthetic runtime");
    }
    for (const name of ["AppIcon.icns", "index.json"])
      writeFileSync(join(contents, "Resources", name), "synthetic resource");
    writeFileSync(
      join(contents, "Resources/ed-launcher"),
      "#!/bin/sh\nexit 0\n",
    );
    symlinkSync("../Resources/ed-launcher", join(contents, "MacOS/ed"));
    if (extra) mkdirSync(join(app, extra), { recursive: true });
    return spawnSync(
      "python3",
      [
        "-c",
        `import sys, plistlib
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from verify_shipping_host import extension_point_descriptor, inspect_layout
app = Path(sys.argv[2])
plist = dict(CFBundleIdentifier='com.pulkit.edith', CFBundleDisplayName='Edith', CFBundleExecutable='Edith', SUPublicEDKey='synthetic-key', SUFeedURL='https://github.com/pulkitxm/edith/releases/latest/download/appcast.xml')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
points = app/'Contents/Extensions'
points.mkdir(parents=True, exist_ok=True)
(points/'ExtensionUI.appextensionpoints').write_bytes(plistlib.dumps(extension_point_descriptor(sys.argv[3] or plist['CFBundleIdentifier'])))
label = 'com.pulkit.edith.extensions.carrier.v1'
daemons = app/'Contents/Library/LaunchDaemons'
daemons.mkdir(parents=True, exist_ok=True)
(daemons/(label+'.plist')).write_bytes(plistlib.dumps(dict(Label=label, BundleProgram='Contents/MacOS/Edith', ProgramArguments=['Edith', '--extension-carrier'], MachServices={label: True})))
inspect_layout(app, release=True)
`,
        resolve("scripts"),
        app,
        pointIdentifier ?? "",
      ],
      { encoding: "utf8" },
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

test("empty release bundle accepts only Sparkle", () => {
  const result = verify();
  expect(result.status, result.stderr).toBe(0);
});

test.each(required)("release bundle rejects missing %s", (missing) => {
  expect(verify({ missing }).status).not.toBe(0);
});

test.each([
  "Contents/Extensions/Feature.appex",
  "Contents/Extensions/extra.appextensionpoints",
  "Contents/Frameworks/ExtensionMarketplace.framework/ExtensionMarketplace.framework",
  "Contents/Frameworks/EdithShared.framework",
  "Contents/Frameworks/MeetingVoice.framework",
  "Contents/Library/LoginItems/Edith.app/Contents/Frameworks/MeetingVoice.framework",
  "Contents/Frameworks/onnxruntime.framework",
  "Contents/Library/LoginItems/Edith.app/Contents/Frameworks/onnxruntime.framework",
  "Contents/MacOS/downloaded-worker",
  "Contents/Resources/GhosttyResources",
])("release bundle rejects bundled feature payloads at %s", (extra) => {
  expect(verify({ extra }).status).not.toBe(0);
});

test("host rejects a public extension point belonging to another app identity", () => {
  expect(
    verify({ pointIdentifier: "com.pulkit.edith.dev.foreign" }).status,
  ).not.toBe(0);
});
