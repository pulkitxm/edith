import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const mergeWorkflow = readFileSync(
  ".github/workflows/release-on-merge.yml",
  "utf8",
);
const tagWorkflow = readFileSync(".github/workflows/release.yml", "utf8");
const makefile = readFileSync("Makefile", "utf8");
const stepTagOutput = ["$", "{{ steps.version.outputs.tag }}"].join("");
const jobTagOutput = ["$", "{{ needs.version.outputs.release_tag }}"].join("");
const releaseRef = ["$", "{{ inputs.release_tag || github.ref_name }}"].join(
  "",
);

test("merge workflow invokes the reusable release after tagging", () => {
  expect(mergeWorkflow).toContain(`release_tag: ${stepTagOutput}`);
  expect(mergeWorkflow).toContain("uses: ./.github/workflows/release.yml");
  expect(mergeWorkflow).toContain(`release_tag: ${jobTagOutput}`);
  expect(mergeWorkflow).not.toContain("gh release create");
  expect(mergeWorkflow).not.toContain("HAS_NOTARY");
});

test("tag workflow supports direct and reusable releases", () => {
  expect(tagWorkflow).toContain("workflow_call:");
  expect(tagWorkflow).toContain('tags: ["v*"]');
  expect(tagWorkflow).toContain(`ref: ${releaseRef}`);
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

test("manual release delegates asset publication to the tag workflow", () => {
  expect(makefile).toContain('git push --atomic origin HEAD:main "v$(V)"');
  expect(makefile).not.toContain("gh release create");
  expect(makefile).not.toContain("generate_appcast");
});
