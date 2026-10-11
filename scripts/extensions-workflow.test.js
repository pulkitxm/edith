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
  expect(build.needs).toEqual(["plan", "frozen-host"]);
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
  expect(build.if).toContain("needs.plan.result == 'success'");
  expect(build.if).toContain("needs['frozen-host'].result == 'success'");
  expect(build.if).toContain("needs.plan.outputs.changed == 'true'");
  expect(publish.needs).toEqual(["plan", "build", "tests"]);
  expect(publish.if).toContain("needs.tests.result == 'success'");
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

test("PR planning fetches the exact trusted base while releases retain signed catalog planning", () => {
  const checkout = plan.steps.find((step) =>
    step.uses?.startsWith("actions/checkout@"),
  );
  expect(checkout.with["fetch-depth"]).toBe(0);
  expect(checkout.with["persist-credentials"]).toBe(false);
  const planning = plan.steps.find((step) => step.id === "plan");
  expect(planning.env.PR_BASE_SHA).toMatch(
    /^\$\{\{ github\.event\.pull_request\.base\.sha \}\}$/,
  );
  expect(planning.run).toContain('[[ "$PR_BASE_SHA" =~ ^[a-f0-9]{40}$ ]]');
  expect(planning.run).toContain('git fetch --no-tags origin "$PR_BASE_SHA"');
  const pr = planning.run.slice(0, planning.run.indexOf("else\n"));
  expect(planning.run).toContain(
    'if [ "$GITHUB_EVENT_NAME" = pull_request ]; then',
  );
  expect(planning.run.indexOf("git fetch")).toBeLessThan(
    planning.run.indexOf("--pull-request-base"),
  );
  expect(pr).toContain('--pull-request-base "$PR_BASE_SHA"');
  expect(pr).not.toContain("--read-catalog");
  expect(planning.run).toContain("else\n");
  expect(planning.run.slice(planning.run.indexOf("else\n"))).toContain(
    "extension-publish.mjs --read-catalog",
  );
  expect(planning.run.slice(planning.run.indexOf("else\n"))).toContain(
    "extension-release-plan.mjs dist/extensions/previous.json",
  );
  expect(planning.run).toContain("draft=false");
  expect(planning.run).toContain('echo "draft=$draft"');
  const source = readFileSync("scripts/extension-release-plan.mjs", "utf8");
  expect(source).toContain('process.env.GITHUB_EVENT_NAME !== "pull_request"');
  expect(publish.if).toContain("github.event_name != 'pull_request'");
  expect(publish.if).toContain("github.ref == 'refs/heads/main'");
});

test("frozen lifecycle tools include and verify their exact sibling source index", () => {
  const packaging = frozen.steps.find((step) =>
    step.run?.includes("package_extension_lifecycle_tools.py --host "),
  );
  expect(packaging).toBeDefined();
  expect(packaging.run).toContain("--host local/minimal-host/Edith.app");
  expect(packaging.run).toContain("--output local/extension-tools");
  expect(packaging.run).toContain("--host-products");
  expect(packaging.run).toContain("--marketplace-products");
  expect(packaging.run).toContain("--show-bin-path");
  expect(packaging.run).not.toContain("cp ");
  const archive = frozen.steps.findIndex((step) =>
    step.run?.includes("tar -czf"),
  );
  expect(frozen.steps.indexOf(packaging)).toBeLessThan(archive);
  expect(frozen.steps[archive].run).toContain("local/extension-tools");
  for (const job of [workflow.jobs.tests, build]) {
    const restore = job.steps.findIndex((step) =>
      step.run?.includes("tar -xzf"),
    );
    const verification = job.steps.findIndex((step) =>
      step.run?.includes("package_extension_lifecycle_tools.py --verify"),
    );
    expect(verification).toBe(restore + 1);
    expect(job.steps[verification].run).toContain(
      "--host local/minimal-host/Edith.app --output local/extension-tools",
    );
  }
  expect(text(plan)).toContain("test-package-extension-lifecycle-tools.py");
});

test("lifecycle tool packaging does not alter any shipping package fingerprint input", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(definitions).toHaveLength(39);
  expect(
    planExtensionBuilds(definitions, [
      "scripts/package_extension_lifecycle_tools.py",
      "scripts/test-package-extension-lifecycle-tools.py",
      "scripts/extensions-workflow.test.js",
      ".github/workflows/extensions.yml",
    ]),
  ).toEqual([]);
});

test("package build job names bind the closed artifact intake to one owner", () => {
  expect(workflow.jobs.build.name).toBe(
    ["build ($", "{{ matrix.id }})"].join(""),
  );
});

test("every package checkout binds artifacts to the API run head instead of a merge ref", () => {
  const expected = [
    "$",
    "{{ github.event.pull_request.head.sha || github.sha }}",
  ].join("");
  for (const job of Object.values(workflow.jobs)) {
    const checkout = job.steps.filter((step) =>
      step.uses?.startsWith("actions/checkout@"),
    );
    expect(checkout).toHaveLength(1);
    expect(checkout[0].with.ref).toBe(expected);
    expect(checkout[0].with["persist-credentials"]).toBe(false);
  }
});

function routingContext(changes = {}) {
  return {
    needs: {
      plan: {
        result: "success",
        outputs: { changed: "true", draft: "false" },
      },
      "frozen-host": { result: "success" },
      tests: { result: "success" },
      build: { result: "success" },
      ...changes.needs,
    },
    github: {
      repository: "pulkitxm/edith",
      event_name: "push",
      ref: "refs/heads/main",
      ...changes.github,
    },
    inputs: { publish: true, ...changes.inputs },
    cancelled: changes.cancelled ?? false,
  };
}

function jobAdmitted(job, context) {
  const needs = Object.fromEntries(
    (job.needs ?? []).map((name) => [name, context.needs[name]]),
  );
  const succeeded = Object.values(needs).every(
    (dependency) => dependency.result === "success",
  );
  const explicitStatus = /\b(always|cancelled|failure|success)\s*\(/.test(
    job.if,
  );
  if (!explicitStatus && (context.cancelled || !succeeded)) return false;
  return Boolean(
    new Function(
      "needs",
      "github",
      "inputs",
      "cancelled",
      "success",
      `return (${job.if});`,
    )(
      needs,
      context.github,
      context.inputs,
      () => context.cancelled,
      () => succeeded,
    ),
  );
}

test("changed worker builds overlap global tests but require the successful frozen plan", () => {
  for (const result of ["success", "failure", "skipped", "cancelled"]) {
    const context = routingContext({ needs: { tests: { result } } });
    expect(jobAdmitted(build, context)).toBe(true);
    expect(jobAdmitted(publish, context)).toBe(result === "success");
  }
  for (const dependency of ["plan", "frozen-host"]) {
    for (const result of ["failure", "skipped", "cancelled"]) {
      const context = routingContext({
        needs: {
          [dependency]: {
            result,
            outputs: { changed: "true", draft: "false" },
          },
        },
      });
      expect(jobAdmitted(build, context)).toBe(false);
    }
  }
  expect(jobAdmitted(build, routingContext({ cancelled: true }))).toBe(false);
});

test("unchanged draft resumes freeze and test the host before publication", () => {
  const context = routingContext({
    needs: {
      plan: {
        result: "success",
        outputs: { changed: "false", draft: "true" },
      },
      build: { result: "skipped" },
    },
  });
  expect(jobAdmitted(frozen, context)).toBe(true);
  expect(jobAdmitted(workflow.jobs.tests, context)).toBe(true);
  expect(jobAdmitted(build, context)).toBe(false);
  expect(jobAdmitted(publish, context)).toBe(true);
  context.needs.plan.outputs.draft = "false";
  expect(jobAdmitted(frozen, context)).toBe(false);
  expect(jobAdmitted(publish, context)).toBe(false);
});

test("both publication paths require successful independent tests and their exact build outcome", () => {
  for (const changed of ["true", "false"]) {
    for (const result of ["failure", "skipped", "cancelled"]) {
      for (const dependency of ["plan", "tests"]) {
        const context = routingContext({
          needs: {
            plan: {
              result: "success",
              outputs: { changed, draft: "true" },
            },
            build: {
              result: changed === "true" ? "success" : "skipped",
            },
          },
        });
        context.needs[dependency].result = result;
        expect(jobAdmitted(publish, context)).toBe(false);
      }
    }
    for (const result of ["success", "failure", "skipped", "cancelled"]) {
      const context = routingContext({
        needs: {
          plan: {
            result: "success",
            outputs: { changed, draft: "true" },
          },
          build: { result },
        },
      });
      expect(jobAdmitted(publish, context)).toBe(
        result === (changed === "true" ? "success" : "skipped"),
      );
      context.cancelled = true;
      expect(jobAdmitted(publish, context)).toBe(false);
    }
  }
});

test("failed frozen or planning gates prevent real tests on changed and draft paths", () => {
  for (const changed of ["true", "false"]) {
    for (const result of ["failure", "skipped", "cancelled"]) {
      const context = routingContext({
        needs: {
          plan: {
            result,
            outputs: { changed, draft: "true" },
          },
          "frozen-host": { result },
          tests: { result: "skipped" },
          build: { result: "skipped" },
        },
      });
      expect(jobAdmitted(frozen, context)).toBe(false);
      expect(jobAdmitted(workflow.jobs.tests, context)).toBe(false);
      expect(jobAdmitted(build, context)).toBe(false);
      expect(jobAdmitted(publish, context)).toBe(false);
    }
  }
});

test("publication rejects untrusted repositories refs and implicit manual publishing", () => {
  for (const changed of ["true", "false"]) {
    const context = routingContext({
      needs: {
        plan: {
          result: "success",
          outputs: { changed, draft: "true" },
        },
        build: { result: changed === "true" ? "success" : "skipped" },
      },
    });
    for (const github of [
      { repository: "synthetic/edith" },
      { ref: "refs/heads/feature" },
      { ref: "refs/tags/v1.2.3" },
      { event_name: "pull_request" },
      { event_name: "workflow_run" },
    ]) {
      expect(
        jobAdmitted(publish, {
          ...context,
          github: { ...context.github, ...github },
        }),
      ).toBe(false);
    }
    const manual = {
      ...context,
      github: { ...context.github, event_name: "workflow_dispatch" },
    };
    expect(jobAdmitted(publish, manual)).toBe(true);
    expect(
      jobAdmitted(publish, { ...manual, inputs: { publish: false } }),
    ).toBe(false);
  }
});

test("all extension pipeline ABI preflights validate committed source without generation", () => {
  for (const job of [plan, frozen, workflow.jobs.tests, build, publish]) {
    const checks = job.steps.filter((step) =>
      step.run?.includes("bun scripts/extension-host-abi.mjs"),
    );
    expect(checks).toHaveLength(1);
    expect(checks[0].run).toBe("bun scripts/extension-host-abi.mjs --check");
  }
  expect(
    frozen.steps.findIndex((step) =>
      step.run?.includes("bun scripts/extension-host-abi.mjs"),
    ),
  ).toBeLessThan(
    frozen.steps.findIndex((step) => step.run === "make ci-host host"),
  );
});
