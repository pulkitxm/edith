import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";

const workflow = Bun.YAML.parse(
  readFileSync(".github/workflows/extensions.yml", "utf8"),
);
const { plan, build, publish } = workflow.jobs;
const text = (value) => JSON.stringify(value).replaceAll("\\n", "\n");

test("release asset helper changes run the extension checks", () => {
  expect(workflow.on.pull_request.paths).toContain("scripts/release-asset-*");
  expect(workflow.on.push.paths).toContain("scripts/release-asset-*");
});

test("extension builds consume independent fingerprints without a feature framework host", () => {
  expect(plan.outputs.matrix).toContain("steps.plan.outputs.matrix");
  expect(text(plan)).toContain("extension-release-plan.mjs");
  expect(workflow.jobs.host).toBeUndefined();
  expect(plan.outputs.host).toBeUndefined();
  expect(build.needs).toEqual(["tests", "plan"]);
  expect(text(build)).not.toContain("host-interfaces");
  expect(text(build)).not.toContain("EXTENSION_HOST_PRODUCTS");
  const cache = build.steps.find(
    (step) =>
      step.name === "Reuse this extension's unchanged support libraries",
  );
  expect(cache.with.key).toContain("matrix.supportFingerprint");
  expect(cache.with.key).toContain("matrix.id");
  expect(build.strategy.matrix).toContain("needs.plan.outputs.matrix");
});

test("every extension passes native lifecycle checks before release signing", () => {
  const guard = build.steps.findIndex(
    (step) => step.name === "Require a native worker package",
  );
  const lifecycle = build.steps.findIndex(
    (step) =>
      step.name ===
      "Build the isolated host and exercise this worker's lifecycle",
  );
  const signing = build.steps.findIndex(
    (step) => step.name === "Import the release signing certificate",
  );
  const bundle = build.steps.findIndex(
    (step) => step.name === "Build only this extension",
  );
  expect(guard).toBeGreaterThan(-1);
  expect(build.steps[guard].run).toContain("contractVersion!==1");
  expect(build.steps[guard].run).toContain("surfaceContractVersion!==1");
  expect(build.steps[guard].run).toContain("usesHostFramework");
  expect(guard).toBeLessThan(lifecycle);
  expect(lifecycle).toBeLessThan(signing);
  expect(signing).toBeLessThan(bundle);
  expect(build.steps[lifecycle].run).toContain("make host");
  expect(build.steps[lifecycle].run).toContain(
    "make ci-extension-workers EXTENSION=",
  );
  expect(build.steps[bundle].run).toContain('"$EXTENSION_ID" --development');
  expect(text(build)).toContain("secrets.MACOS_CERT_P12");
  expect(text(build)).toContain("secrets.NOTARY_KEY");
});

test("only successful changed extension builds can publish", () => {
  expect(build.if).toContain("!cancelled()");
  expect(build.if).toContain("needs.tests.result == 'success'");
  expect(build.if).toContain("needs.plan.outputs.changed == 'true'");
  expect(publish.needs).toEqual(["plan", "build"]);
  expect(publish.if).toContain("github.event_name != 'pull_request'");
  expect(publish.if).toContain("github.ref == 'refs/heads/main'");
  expect(publish.if).toContain("needs.plan.outputs.changed == 'true'");
  expect(text(publish)).toContain("pukbot capabilities --json");
  expect(text(publish)).toContain("extension-publish.mjs");
  expect(text(publish)).toContain("EXTENSION_CATALOG_PRIVATE_KEY");
});

test("terminal dependencies are restored before native lifecycle builds", () => {
  const native = build.steps.findIndex((step) => step.id === "native");
  const cache = build.steps.findIndex(
    (step) => step.name === "Cache the optional terminal library",
  );
  const bootstrap = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const lifecycle = build.steps.findIndex(
    (step) =>
      step.name ===
      "Build the isolated host and exercise this worker's lifecycle",
  );
  expect(native).toBeGreaterThan(-1);
  expect(native).toBeLessThan(cache);
  expect(cache).toBeLessThan(bootstrap);
  expect(bootstrap).toBeLessThan(lifecycle);
  expect(build.steps[native].run).toContain(
    'nativeProduct==="GhosttyTerminal"',
  );
  expect(build.steps[cache].with.path).toBe(
    "Extensions/terminal/Native/vendor",
  );
  expect(build.steps[cache].if).toBe("steps.native.outputs.ghostty == 'true'");
  expect(build.steps[bootstrap].if).toBe(build.steps[cache].if);
  expect(build.steps[bootstrap].run).toContain("make ghostty-extension");
});

test("common extension checks do not repeat every native release build", () => {
  const checks = text(workflow.jobs.tests);
  expect(checks).toContain("ci-extension-support");
  expect(checks).toContain("ci-marketplace-runtime");
  expect(checks).toContain("ci-extension-commands");
  expect(checks).not.toContain("ci-marketplace-host");
  expect(checks).not.toContain("ci-extension-workers");
  expect(text(build)).toContain("ci-extension-workers EXTENSION=");
});

test("selected optional native suites gate lifecycle and release signing", () => {
  const suites = build.steps.findIndex(
    (step) => step.name === "Test this extension's optional native packages",
  );
  const prerequisites = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const lifecycle = build.steps.findIndex(
    (step) =>
      step.name ===
      "Build the isolated host and exercise this worker's lifecycle",
  );
  const cache = build.steps.findIndex(
    (step) =>
      step.name === "Reuse this extension's unchanged support libraries",
  );
  expect(suites).toBeGreaterThan(prerequisites);
  expect(cache).toBeLessThan(suites);
  expect(suites).toBeLessThan(lifecycle);
  expect(build.steps[suites].env.EXTENSION_ID).toContain("matrix.id");
  expect(build.steps[suites].run).toBe(
    'bun scripts/test-extension-package.mjs "$EXTENSION_ID"',
  );
});
