import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { planExtensionBuilds } from "./extension-release-plan.mjs";

const workflow = Bun.YAML.parse(
  readFileSync(".github/workflows/extensions.yml", "utf8"),
);
const { plan, build, publish } = workflow.jobs;
const frozen = workflow.jobs["frozen-host"];
const text = (value) => JSON.stringify(value).replaceAll("\\n", "\n");

test("portable planning uses Ubuntu while native checks and publication keep macOS", () => {
  expect(plan["runs-on"]).toBe("ubuntu-latest");
  for (const job of [workflow.jobs.tests, build, publish])
    expect(job["runs-on"]).toBe("macos-26");
  expect(text(plan)).toContain(
    "node scripts/extension-publish.mjs --read-catalog",
  );
  expect(text(plan)).toContain(
    "node --test scripts/verify-extension-catalog.test.mjs",
  );
  expect(text(plan)).not.toContain("swift ");
  expect(
    plan.steps.find((step) => step.uses?.startsWith("actions/setup-node@"))
      .with["node-version"],
  ).toBe(24);
  expect(text(publish)).toContain("extension-publish.mjs");
  expect(readFileSync("scripts/extension-publish.mjs", "utf8")).toContain(
    "extension-catalog-sign.swift",
  );
});

test("downloaded Docs source and reference changes run independent package checks", () => {
  for (const event of [workflow.on.pull_request, workflow.on.push]) {
    expect(event.paths).toContain("Packages/EdithDocsWorker/**");
    expect(event.paths).toContain("docs/cli/**");
    expect(event.paths).toContain("scripts/generate-cli-docs-bundle.mjs");
  }
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(
    planExtensionBuilds(definitions, [
      "Packages/EdithDocsWorker/Sources/EdithDocsWorker/Resources/cli-docs.json",
    ]).map(({ id }) => id),
  ).toEqual(["docs"]);
});

test("maintained terminal native inputs trigger selective extension checks", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  const inputs = [
    "scripts/build-ghostty.sh",
    "scripts/patches/ghostty-external-io.patch",
    "scripts/extension-ghostty-native.mjs",
  ];
  for (const path of inputs) {
    for (const event of [workflow.on.pull_request, workflow.on.push]) {
      expect(
        event.paths.some((pattern) => new Bun.Glob(pattern).match(path)),
      ).toBe(true);
    }
    expect(
      planExtensionBuilds(definitions, [path]).map(({ id }) => id),
    ).toEqual(["terminal", "machines", "herdr", "quinjet"]);
  }
});

test("all extension releases reuse one signed host without Camera provisioning", () => {
  const signing = frozen.steps.findIndex(
    (step) => step.name === "Import the release signing certificate",
  );
  const preparation = frozen.steps.findIndex(
    (step) =>
      step.name ===
      "Freeze the production host once for all changed extensions",
  );
  expect(preparation).toBeGreaterThan(signing);
  expect(frozen.steps[preparation].run).toContain("package-shipping-host.py");
  expect(frozen.steps[preparation].run).toContain("--release");
  expect(text(frozen)).not.toContain("CAMERA_CARRIER_PROVISIONING_PROFILE");
  expect(text(frozen)).not.toContain("CAMERA_EXTENSION_PROVISIONING_PROFILE");
  const packaging = build.steps.find(
    (step) => step.name === "Build only this extension",
  );
  expect(packaging.env.EXTENSION_CONTAINING_HOST_APP).toContain(
    "local/extension-release-host/Edith.app",
  );
  expect(packaging.env.EXTENSION_CONTAINING_HOST_APP).toContain(
    "local/minimal-host/Edith.app",
  );
  for (const job of [frozen, build])
    expect(job.steps.at(-1).if).toBe("always()");
});

test("release asset helper changes run the extension checks", () => {
  expect(workflow.on.pull_request.paths).toContain("scripts/release-asset-*");
  expect(workflow.on.push.paths).toContain("scripts/release-asset-*");
});

test("extension builds consume independent fingerprints without a feature framework host", () => {
  expect(plan.outputs.matrix).toContain("steps.plan.outputs.matrix");
  expect(text(plan)).toContain("extension-release-plan.mjs");
  expect(workflow.jobs.host).toBeUndefined();
  expect(plan.outputs.host).toBeUndefined();
  expect(build.needs).toEqual(["tests", "plan", "frozen-host"]);
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
    (step) => step.name === "Exercise this worker against the frozen host",
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
  expect(build.steps[lifecycle].run).not.toContain("make host");
  expect(text(frozen)).toContain("make ci-host host");
  expect(build.steps[lifecycle].run).toContain("test-extension-workers.mjs");
  expect(build.steps[bundle].run).toContain('"$EXTENSION_ID" --development');
  expect(text(build)).toContain("secrets.MACOS_CERT_P12");
  expect(text(build)).toContain("secrets.NOTARY_KEY");
});

test("changed packages require successful builds before publication", () => {
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

test("manual publication is explicit and checked builds can publish from main", () => {
  expect(workflow.on.workflow_dispatch.inputs.publish).toEqual({
    description:
      "Publish verified packages and the signed catalog from this ref",
    type: "boolean",
    required: true,
    default: false,
  });
  expect(publish.if).toContain("needs.build.result == 'success'");
  expect(publish.if).toContain(
    "github.event_name == 'workflow_dispatch' && inputs.publish == true",
  );
  const signing = build.steps.find(
    (step) => step.name === "Import the release signing certificate",
  );
  expect(signing.if).toContain("inputs.publish == true");
  const packaging = build.steps.find(
    (step) => step.name === "Build only this extension",
  );
  expect(packaging.env.DEVELOPMENT).toContain("inputs.publish != true");
  expect(publish.env.GH_TOKEN).toContain("secrets.RELEASE_PUSH_TOKEN");
  expect(publish.env.EXTENSION_CATALOG_PRIVATE_KEY).toContain(
    "secrets.EXTENSION_CATALOG_PRIVATE_KEY",
  );
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
    (step) => step.name === "Exercise this worker against the frozen host",
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
  expect(text(build)).toContain("test-extension-workers.mjs");
});

test("selected optional native suites gate lifecycle and release signing", () => {
  const suites = build.steps.findIndex(
    (step) => step.name === "Test this extension's optional native packages",
  );
  const prerequisites = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const lifecycle = build.steps.findIndex(
    (step) => step.name === "Exercise this worker against the frozen host",
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

test("matrix jobs restore executable modes and never rebuild the shared host", () => {
  for (const job of [workflow.jobs.tests, build]) {
    expect(job.needs).toContain("frozen-host");
    expect(text(job)).toContain("frozen-extension-host");
    expect(text(job)).toContain("tar -xzf");
    expect(text(job)).not.toContain("make host");
  }
  expect(frozen["runs-on"]).toBe("macos-26");
  expect(text(frozen)).toContain("tar -czf");
  expect(text(frozen)).toContain("HostLifecycleHarness");
  expect(text(frozen)).toContain("MarketplaceHarness");
});

test("native cache keys include maintained patch and exact toolchain; validation gates release signing", () => {
  const toolchain = build.steps.findIndex(
    (step) => step.id === "ghostty-toolchain",
  );
  const cache = build.steps.findIndex(
    (step) => step.name === "Cache the optional terminal library",
  );
  const validation = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const signing = build.steps.findIndex(
    (step) => step.name === "Import the release signing certificate",
  );
  expect(toolchain).toBeGreaterThan(-1);
  expect(toolchain).toBeLessThan(cache);
  expect(cache).toBeLessThan(validation);
  expect(validation).toBeLessThan(signing);
  expect(build.steps[cache].with.key).toContain(
    "scripts/patches/ghostty-external-io.patch",
  );
  expect(build.steps[cache].with.key).toContain(
    "steps.ghostty-toolchain.outputs.fingerprint",
  );
  expect(build.steps[toolchain].run).toContain(
    "extension-ghostty-native.mjs --fingerprint",
  );
  expect(build.steps[validation].run).toContain(
    "extension-ghostty-native.mjs --check",
  );
  expect(build.steps[validation].run).toContain(
    "extension-ghostty-native.test.js",
  );
  expect(build.steps[validation]["continue-on-error"]).toBeUndefined();
});

test("common frozen runtime changes rebuild all39 while Camera-only packaging stays selective", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(definitions).toHaveLength(39);
  const common = "scripts/build-contained-host-runtime.mjs";
  const camera = "scripts/build-camera-carrier.mjs";
  for (const event of [workflow.on.pull_request, workflow.on.push]) {
    for (const path of [common, camera])
      expect(
        event.paths.some((pattern) => new Bun.Glob(pattern).match(path)),
      ).toBe(true);
  }
  expect(
    planExtensionBuilds(definitions, [common]).map(({ id }) => id),
  ).toEqual(definitions.map(({ id }) => id));
  expect(
    planExtensionBuilds(definitions, [camera]).map(({ id }) => id),
  ).toEqual(["virtualCamera"]);
});

test("signed retained catalogs must pass actual native selection before package publication", () => {
  expect(text(workflow.jobs.tests)).toContain(
    "test-extension-catalog-retention.mjs",
  );
  expect(workflow.jobs.tests.needs).toContain("frozen-host");
});
