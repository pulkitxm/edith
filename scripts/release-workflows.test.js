import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const mergeWorkflow = readFileSync(
  ".github/workflows/release-on-merge.yml",
  "utf8",
);
const tagWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const makefile = readFileSync("Makefile", "utf8");
const ciWorkflow = readFileSync(".github/workflows/ci.yml", "utf8");
const releaseRef = ["$", "{{ github.ref_name }}"].join("");

test("merge workflow only bumps and tags", () => {
  expect(mergeWorkflow).toContain('git tag "v${NEXT}"');
  expect(mergeWorkflow).toContain('git push origin "v${NEXT}"');
  expect(mergeWorkflow).not.toContain("uses: ./.github/workflows/release.yml");
  expect(mergeWorkflow).not.toContain("gh release create");
  expect(mergeWorkflow).not.toContain("HAS_NOTARY");
});

test("one release run per tag, triggered by the tag alone", () => {
  expect(tagWorkflow).not.toContain("workflow_call:");
  expect(tagWorkflow).not.toContain("inputs.release_tag");
  expect(tagWorkflow).toContain('tags: ["v*"]');
  expect(tagWorkflow).toContain(`ref: ${releaseRef}`);
});

test("automated commits do not re-run CI", () => {
  expect(ciWorkflow).toContain("'Bump version to '");
  expect(ciWorkflow).toContain("'Update the Homebrew cask to '");
  expect(ciWorkflow).toContain("github.event_name != 'push'");
});

test("release waits for and publishes every platform asset", () => {
  expect(tagWorkflow).toContain("needs: [dmg, deb]");
  expect(tagWorkflow).toContain("release-assets/Edith.dmg");
  expect(tagWorkflow).toContain("release-assets/Edith.deb");
  expect(tagWorkflow).toContain("release-assets/appcast.xml");
  expect(tagWorkflow).toContain("-name 'edith_*.deb'");
  expect(tagWorkflow).toContain("gh release create");
  expect(tagWorkflow).toContain("gh release upload");
  expect(tagWorkflow).toContain('apt-get install -y "./$DEB"');
});

test("macOS notarization is conditional on its optional credentials", () => {
  expect(tagWorkflow).toContain("HAS_NOTARY:");
  expect(tagWorkflow).toContain("if: env.HAS_NOTARY == 'true'");
  expect(tagWorkflow).not.toContain("env.HAS_NOTARY != 'true'");
});

test("macOS release accepts the configured development certificate", () => {
  expect(tagWorkflow).toContain('EDITH_RELEASE_ALLOW_DEV_SIGNING: "1"');
});

test("jobs that push to main use a token that clears the ruleset", () => {
  const pushToken = ["$", "{{ secrets.RELEASE_PUSH_TOKEN }}"].join("");
  expect(mergeWorkflow).toContain(`token: ${pushToken}`);
  expect(mergeWorkflow).toContain("RELEASE_PUSH_TOKEN is required");
  expect(tagWorkflow).toContain(`token: ${pushToken}`);
});

test("manual release delegates asset publication to the tag workflow", () => {
  expect(makefile).toContain('git push --atomic origin HEAD:main "v$(V)"');
  expect(makefile).not.toContain("gh release create");
  expect(makefile).not.toContain("generate_appcast");
});
