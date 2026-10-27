import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  copyFileSync,
  mkdirSync,
  mkdtempSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const required = ["Sparkle.framework"];

function verify({ missing, extra, artwork = "valid", carrier = "valid" } = {}) {
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
    if (artwork !== "missing") {
      const artworkBundle = join(
        contents,
        "Resources/EdithHost_EdithHost.bundle",
      );
      mkdirSync(artworkBundle);
      const archive = join(artworkBundle, "MarketplaceArtwork.lzma");
      copyFileSync(
        resolve(
          "Packages/EdithHost/Sources/EdithHost/Resources/MarketplaceArtwork.lzma",
        ),
        archive,
      );
      if (artwork === "corrupt") writeFileSync(archive, "invalid artwork");
      if (artwork === "extra")
        writeFileSync(join(artworkBundle, "unexpected.bin"), "extra resource");
    }
    writeFileSync(
      join(contents, "Resources/ed-launcher"),
      "#!/bin/sh\nexit 0\n",
    );
    symlinkSync("../Resources/ed-launcher", join(contents, "MacOS/ed"));
    const daemons = join(contents, "Library/LaunchDaemons");
    mkdirSync(daemons, { recursive: true });
    if (carrier !== "missing")
      copyFileSync(
        resolve("Resources/com.pulkit.edith.extensions.carrier.v1.plist"),
        join(daemons, "com.pulkit.edith.extensions.carrier.v1.plist"),
      );
    if (extra) mkdirSync(join(app, extra), { recursive: true });
    return spawnSync(
      "python3",
      [
        "-c",
        `import sys, plistlib
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from verify_shipping_host import inspect_layout
app = Path(sys.argv[2])
plist = dict(CFBundleIdentifier='com.pulkit.edith', CFBundleDisplayName='Edith', CFBundleExecutable='Edith', SUPublicEDKey='synthetic-key', SUFeedURL='https://github.com/pulkitxm/edith/releases/latest/download/appcast.xml')
(app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
inspect_layout(app, release=True)
`,
        resolve("scripts"),
        app,
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

test.each(["missing", "corrupt", "extra"])(
  "release bundle rejects %s artwork resources",
  (artwork) => {
    const result = verify({ artwork });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toMatch(/artwork/i);
  },
);

test("release bundle requires the privileged carrier daemon", () => {
  expect(verify({ carrier: "missing" }).status).not.toBe(0);
});

test.each(required)("release bundle rejects missing %s", (missing) => {
  expect(verify({ missing }).status).not.toBe(0);
});

test.each([
  "Contents/Extensions/Feature.appex",
  "Contents/Library/LaunchAgents",
  "Contents/Frameworks/ExtensionMarketplace.framework/ExtensionMarketplace.framework",
  "Contents/Frameworks/EdithShared.framework",
  "Contents/MacOS/downloaded-worker",
  "Contents/Resources/GhosttyResources",
])("release bundle rejects bundled feature payloads at %s", (extra) => {
  expect(verify({ extra }).status).not.toBe(0);
});
