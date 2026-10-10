import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";
import { planExtensionBuilds } from "./extension-release-plan.mjs";

test("camera-specific app and release preparation changes select only their consumers", async () => {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  for (const source of [
    "Packages/EdithHost/Sources/EdithHost/HostApplication.swift",
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

test("shared host packaging changes rebuild all same-executable consumers", async () => {
  const definitions = JSON.parse(
    await readFile("Extensions/manifest.json", "utf8"),
  );
  for (const source of [
    "Packages/EdithHost/Package.swift",
    "Packages/EdithHost/Package.resolved",
    "scripts/build-minimal-host.mjs",
    "scripts/package-shipping-host.py",
    "Packages/EdithHost/Sources/EdithHostCore/HostContainedRole.swift",
  ])
    expect(
      planExtensionBuilds(definitions, [source]).map(({ id }) => id),
    ).toEqual(definitions.map(({ id }) => id));
});
