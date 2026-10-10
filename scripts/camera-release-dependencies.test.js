import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { planExtensionBuilds } from "./extension-release-plan.mjs";

test("copied host runtime changes select the camera carrier without rebuilding unrelated workers", async () => {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  for (const source of [
    "Packages/EdithHost/Sources/EdithHostCore/HostContainedRole.swift",
    "Packages/EdithHost/Sources/EdithHost/HostApplication.swift",
    "Packages/EdithHost/Package.swift",
    "Packages/EdithHost/Package.resolved",
    "scripts/build-minimal-host.mjs",
    "scripts/package-shipping-host.py",
    "scripts/prepare-camera-extension-release.py",
  ]) {
    const selected = planExtensionBuilds(definitions, [source]).map(
      ({ id }) => id,
    );
    expect(selected).toContain("virtualCamera");
    expect(selected).not.toContain("calendar");
    expect(selected).not.toContain("clipboard");
  }
});
