import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const cask = readFileSync("Casks/edith.rb", "utf8");
const releaseWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const readme = readFileSync("README.md", "utf8");
const doc = readFileSync("docs/homebrew.md", "utf8");
const site = readFileSync("apps/site/index.html", "utf8");
const deepDoc = readFileSync("docs/homebrew-internals.md", "utf8");
const installCommand = "brew install --cask pulkitxm/tap/edith";
const releaseTagRef = ["$", "{RELEASE_TAG}"].join("");

test("the cask names a released disk image by version", () => {
  expect(cask).toContain('cask "edith" do');
  expect(cask).toMatch(/^ {2}version "\d+\.\d+\.\d+"$/m);
  expect(cask).toMatch(/^ {2}sha256 "[0-9a-f]{64}"$/m);
  expect(cask).toContain(
    'url "https://github.com/pulkitxm/edith/releases/download/v#{version}/Edith.dmg"',
  );
  expect(cask).toContain('app "Edith.app"');
});

test("the cask ships both CLI binaries and defers updates to Sparkle", () => {
  expect(cask).toContain('binary "#{appdir}/Edith.app/Contents/MacOS/ed"');
  expect(cask).toContain('binary "#{appdir}/Edith.app/Contents/MacOS/edh"');
  expect(cask).toContain("auto_updates true");
  expect(cask).toContain('depends_on macos: ">= :sonoma"');
  expect(cask).toContain("depends_on arch: :arm64");
});

test("uninstalling quits every bundle and zapping clears Edith's own state", () => {
  for (const bundleID of [
    "com.pulkit.edith",
    "com.pulkit.edith.statusbar",
    "com.pulkit.edith.files",
  ]) {
    expect(cask).toContain(`"${bundleID}"`);
  }
  expect(cask).toContain('"~/Library/Application Support/Edith"');
  expect(cask).toContain('"~/Library/Caches/Edith"');
  expect(cask).toContain(
    '"~/Library/Preferences/com.pulkit.edith.shared.plist"',
  );
});

test("the release mirrors the bumped cask to the tap repository", () => {
  expect(releaseWorkflow).toContain("github.com/pulkitxm/homebrew-tap.git");
  expect(releaseWorkflow).toContain("TAP_PUSH_TOKEN");
  expect(releaseWorkflow).toContain("cp Casks/edith.rb tap/Casks/edith.rb");
  expect(releaseWorkflow).toContain(
    `git commit -m "Update the Edith cask to ${releaseTagRef}"`,
  );
});

test("the release bumps the cask after the assets are published", () => {
  expect(releaseWorkflow).toContain("needs: publish");
  expect(releaseWorkflow).toContain("sha256sum release-assets/Edith.dmg");
  expect(releaseWorkflow).toContain("Casks/edith.rb");
  expect(releaseWorkflow).toContain(
    `git commit -m "Update the Homebrew cask to ${releaseTagRef}"`,
  );
  expect(releaseWorkflow).toContain("git push origin HEAD:main");
});

test("the deep dive is linked and explains the resolution rules", () => {
  expect(doc).toContain("homebrew-internals.md");
  expect(readme).toContain("docs/homebrew-internals.md");
  expect(deepDoc).toContain("HOMEBREW_TAP_CASK_REGEX");
  expect(deepDoc).toContain("ensure_installed!");
  expect(deepDoc).toContain(installCommand);
  expect(deepDoc.split("\n").length).toBeGreaterThan(1000);
});

test("cask edits run the script tests", () => {
  expect(ciWorkflow).toContain("area scripts '^(scripts/|Casks/|");
});

test("the tap is documented where people look for a download", () => {
  expect(readme).toContain(installCommand);
  expect(site).toContain(installCommand);
  expect(doc).toContain(installCommand);
  expect(doc).toContain("brew upgrade --cask --greedy edith");
  expect(doc).toContain("brew uninstall --cask --zap edith");
});
