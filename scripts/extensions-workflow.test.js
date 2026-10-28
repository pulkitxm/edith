import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { planExtensionBuilds } from "./extension-release-plan.mjs";

const workflow = Bun.YAML.parse(
  readFileSync(".github/workflows/extensions.yml", "utf8"),
);
const { plan, build, publish } = workflow.jobs;
const ci = Bun.YAML.parse(readFileSync(".github/workflows/ci.yml", "utf8"));
const extensionArea = new RegExp(
  ci.jobs.changes.steps
    .find(({ id }) => id === "areas")
    .run.match(/area extensions '([^']+)'/)[1],
);
const routes = (path) => extensionArea.test(path);
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
  for (const path of [
    "Packages/EdithDocsWorker/Sources/EdithDocsWorker/main.swift",
    "docs/cli/index.md",
    "scripts/generate-cli-docs-bundle.mjs",
  ])
    expect(routes(path)).toBe(true);
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
    expect(routes(path)).toBe(true);
    expect(
      planExtensionBuilds(definitions, [path]).map(({ id }) => id),
    ).toEqual(["terminal", "machines", "herdr", "quinjet"]);
  }
});

test("CI routes every explicit maintained producer script to the extension checks", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  const inputs = [
    ...new Set(
      definitions.flatMap(({ inputs, sharedInputs }) => [
        ...inputs,
        ...sharedInputs,
      ]),
    ),
  ].filter((path) => /^scripts\/[^*?[\]{}]+\.(mjs|js|py|sh)$/.test(path));
  expect(inputs.filter((path) => !routes(path))).toEqual([]);
});

test("only the camera carrier build prepares a containing host without Camera provisioning", () => {
  const names = build.steps.map((step) => step.name);
  const signing = names.indexOf("Import the release signing certificate");
  const compile = names.indexOf(
    "Build the host that contains the camera carrier",
  );
  const preparation = names.indexOf("Sign the containing host for publication");
  expect(compile).toBeGreaterThan(signing - 1);
  expect(preparation).toBeGreaterThan(signing);
  for (const index of [compile, preparation])
    expect(build.steps[index].if).toContain("matrix.camera");
  expect(build.steps[compile].run).toBe("make host");
  expect(build.steps[preparation].run).toContain("package-shipping-host.py");
  expect(build.steps[preparation].run).toContain("--release");
  expect(text(build)).not.toContain("CAMERA_CARRIER_PROVISIONING_PROFILE");
  expect(text(build)).not.toContain("CAMERA_EXTENSION_PROVISIONING_PROFILE");
  const packaging = build.steps.find(
    (step) => step.name === "Build only this batch's extensions",
  );
  expect(packaging.env.EXTENSION_CONTAINING_HOST_APP).toContain(
    "local/extension-release-host/Edith.app",
  );
  expect(packaging.env.EXTENSION_CONTAINING_HOST_APP).toContain(
    "local/minimal-host/Edith.app",
  );
  expect(build.steps.at(-1).if).toBe("always()");
});

test("release asset helper changes run the extension checks", () => {
  expect(routes("scripts/release-asset-upload.mjs")).toBe(true);
});

test("extension builds consume independent fingerprints without a feature framework host", () => {
  expect(plan.outputs.matrix).toContain("steps.plan.outputs.matrix");
  expect(text(plan)).toContain("extension-release-plan.mjs");
  expect(workflow.jobs.host).toBeUndefined();
  expect(plan.outputs.host).toBeUndefined();
  expect(build.needs).toEqual(["plan"]);
  expect(text(build)).not.toContain("host-interfaces");
  expect(text(build)).not.toContain("EXTENSION_HOST_PRODUCTS");
  const cache = build.steps.find(
    (step) => step.name === "Reuse this batch's unchanged support libraries",
  );
  expect(cache.with.key).toContain("matrix.supportKey");
  expect(cache.with.path).toBe(["$", "{{ matrix.supportPaths }}"].join(""));
  expect(build.strategy.matrix).toContain("needs.plan.outputs.batches");
  expect(plan.outputs.batches).toContain("steps.plan.outputs.batches");
  expect(text(plan)).toContain("extension-build-batches.mjs");
});

test("every extension passes native package checks before release signing", () => {
  const guard = build.steps.findIndex(
    (step) => step.name === "Require native packages",
  );
  const suites = build.steps.findIndex(
    (step) => step.name === "Test this batch's optional native packages",
  );
  const signing = build.steps.findIndex(
    (step) => step.name === "Import the release signing certificate",
  );
  const bundle = build.steps.findIndex(
    (step) => step.name === "Build only this batch's extensions",
  );
  expect(guard).toBeGreaterThan(-1);
  expect(build.steps[guard].run).toContain("contractVersion!==1");
  expect(build.steps[guard].run).toContain("surfaceContractVersion!==1");
  expect(guard).toBeLessThan(suites);
  expect(suites).toBeLessThan(signing);
  expect(signing).toBeLessThan(bundle);
  expect(build.steps[bundle].run).toContain('flags="--development"');
  expect(build.steps[bundle].run).toContain(
    'bun scripts/build-extension-package.mjs "$id" $flags',
  );
  expect(build.steps[bundle].run).toContain(
    "::error title=Extension build failed::$id",
  );
  expect(text(build)).toContain("secrets.MACOS_CERT_P12");
  expect(text(build)).toContain("secrets.NOTARY_KEY");
});

test("changed packages require successful builds before publication", () => {
  expect(build.if).toContain("!cancelled()");
  expect(build.if).toContain("needs.plan.result == 'success'");
  expect(build.if).toContain("needs.plan.outputs.changed == 'true'");
  expect(publish.needs).toEqual(["plan", "build", "tests"]);
  expect(publish.if).toContain("needs.tests.result == 'success'");
  expect(publish.if).toContain("github.event_name != 'pull_request'");
  expect(publish.if).toContain("github.ref == 'refs/heads/main'");
  expect(publish.if).toContain("needs.plan.outputs.changed == 'true'");
  expect(text(publish)).toContain("pukbot capabilities --json");
  expect(text(publish)).toContain("pukbot tag create --help");
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
    (step) => step.name === "Build only this batch's extensions",
  );
  expect(packaging.env.DEVELOPMENT).toContain("inputs.publish != true");
  expect(publish.env.GH_TOKEN).toContain("secrets.RELEASE_PUSH_TOKEN");
  expect(publish.env.EXTENSION_CATALOG_PRIVATE_KEY).toContain(
    "secrets.EXTENSION_CATALOG_PRIVATE_KEY",
  );
});

test("terminal dependencies are restored before native package checks", () => {
  const native = build.steps.findIndex((step) => step.id === "native");
  const cache = build.steps.findIndex(
    (step) => step.name === "Cache the optional terminal library",
  );
  const bootstrap = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const suites = build.steps.findIndex(
    (step) => step.name === "Test this batch's optional native packages",
  );
  expect(native).toBeGreaterThan(-1);
  expect(native).toBeLessThan(cache);
  expect(cache).toBeLessThan(bootstrap);
  expect(bootstrap).toBeLessThan(suites);
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
  expect(checks).not.toContain("ci-marketplace-host");
  expect(checks).not.toContain("ci-extension-commands");
  expect(checks).not.toContain("ci-extension-workers");
});

test("selected optional native suites gate release signing", () => {
  const suites = build.steps.findIndex(
    (step) => step.name === "Test this batch's optional native packages",
  );
  const prerequisites = build.steps.findIndex(
    (step) => step.name === "Build the optional terminal library",
  );
  const cache = build.steps.findIndex(
    (step) => step.name === "Reuse this batch's unchanged support libraries",
  );
  const signing = build.steps.find(
    (step) => step.name === "Import the release signing certificate",
  );
  expect(suites).toBeGreaterThan(prerequisites);
  expect(cache).toBeLessThan(suites);
  expect(suites).toBeLessThan(build.steps.indexOf(signing));
  expect(build.env.EXTENSION_IDS).toBe(["$", "{{ matrix.ids }}"].join(""));
  expect(build.steps[suites].run).toContain(
    'bun scripts/test-extension-package.mjs "$id"',
  );
  expect(build.steps[suites].run).toContain(
    "::error title=Extension tests failed::$id",
  );
  expect(build.steps[suites].if).toBeUndefined();
  expect(build.steps[suites].env.EXTENSION_PACKAGE_SUITES).toBe(
    `\${{ (${signing.if}) && 'skip' || 'run' }}`,
  );
});

test("matrix jobs never restore a frozen host and only the camera build compiles one", () => {
  for (const job of [workflow.jobs.tests, build]) {
    expect(job.needs).toContain("plan");
    expect(job.needs).not.toContain("frozen-host");
    expect(text(job)).not.toContain("frozen-extension-host");
    expect(text(job)).not.toContain("tar -xzf");
  }
  expect(workflow.jobs["frozen-host"]).toBeUndefined();
  expect(text(workflow)).not.toContain("HostLifecycleHarness");
  expect(text(workflow)).not.toContain("extension-tools");
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

test("camera carrier packaging inputs rebuild only the camera package", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  const camera = [
    "scripts/build-contained-host-runtime.mjs",
    "scripts/build-camera-carrier.mjs",
  ];
  for (const path of camera) expect(routes(path)).toBe(true);
  for (const path of camera) {
    expect(
      planExtensionBuilds(definitions, [path]).map(({ id }) => id),
    ).toEqual(["virtualCamera"]);
  }
});

test("signed retained catalogs must pass actual native selection before package publication", () => {
  expect(text(workflow.jobs.tests)).toContain(
    "test-extension-catalog-retention.mjs",
  );
  expect(workflow.jobs.tests.needs).toContain("plan");
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

test("workflow and test edits do not rebuild shipping packages", () => {
  const definitions = JSON.parse(
    readFileSync("Extensions/manifest.json", "utf8"),
  );
  expect(
    planExtensionBuilds(definitions, [
      "scripts/extensions-workflow.test.js",
      ".github/workflows/extensions.yml",
    ]),
  ).toEqual([]);
});

test("package build job names bind the closed artifact intake to one owner", () => {
  expect(workflow.jobs.build.name).toBe(
    ["build ($", "{{ matrix.ids }})"].join(""),
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

test("changed builds overlap global tests but require the successful plan", () => {
  for (const result of ["success", "failure", "skipped", "cancelled"]) {
    const context = routingContext({ needs: { tests: { result } } });
    expect(jobAdmitted(build, context)).toBe(true);
    expect(jobAdmitted(publish, context)).toBe(result === "success");
  }
  for (const result of ["failure", "skipped", "cancelled"]) {
    const context = routingContext({
      needs: {
        plan: { result, outputs: { changed: "true", draft: "false" } },
      },
    });
    expect(jobAdmitted(build, context)).toBe(false);
  }
  expect(jobAdmitted(build, routingContext({ cancelled: true }))).toBe(false);
});

test("unchanged draft resumes test before publication", () => {
  const context = routingContext({
    needs: {
      plan: {
        result: "success",
        outputs: { changed: "false", draft: "true" },
      },
      build: { result: "skipped" },
    },
  });
  expect(jobAdmitted(workflow.jobs.tests, context)).toBe(true);
  expect(jobAdmitted(build, context)).toBe(false);
  expect(jobAdmitted(publish, context)).toBe(true);
  context.needs.plan.outputs.draft = "false";
  expect(jobAdmitted(workflow.jobs.tests, context)).toBe(false);
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

test("failed planning gates prevent real tests on changed and draft paths", () => {
  for (const changed of ["true", "false"]) {
    for (const result of ["failure", "skipped", "cancelled"]) {
      const context = routingContext({
        needs: {
          plan: {
            result,
            outputs: { changed, draft: "true" },
          },
          tests: { result: "skipped" },
          build: { result: "skipped" },
        },
      });
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
  for (const job of [plan, workflow.jobs.tests, build, publish]) {
    const checks = job.steps.filter((step) =>
      step.run?.includes("bun scripts/extension-host-abi.mjs"),
    );
    expect(checks).toHaveLength(1);
    expect(checks[0].run).toBe("bun scripts/extension-host-abi.mjs --check");
  }
});

test("shipping tests exclude unrelated native models while all-extension validation retains them", () => {
  const checks = workflow.jobs.tests;
  expect(checks.needs).toContain("plan");
  const shipping = checks.steps.find(
    (step) => step.name === "Validate the shipping extension and marketplace",
  );
  expect(shipping.if).toBe("needs.plan.outputs.mode != 'validation'");
  expect(shipping.run).toBe(
    "make ci-marketplace-runtime ci-extension-keep-awake ci-comments",
  );
  const allModels = checks.steps.find(
    (step) =>
      step.name ===
      "Run make ci-marketplace-runtime ci-extension-support ci-extension-docs ci-comments",
  );
  expect(allModels.if).toBe("needs.plan.outputs.mode == 'validation'");
  expect(allModels.run).toContain("ci-extension-support ci-extension-docs");
  const cache = checks.steps.find(
    (step) =>
      step.name === "Verify native cache integrity and private SDK composition",
  );
  expect(cache.if).toBe(allModels.if);
  const fullHost = checks.steps.find(
    (step) => step.run === "make ci-host host",
  );
  expect(fullHost.if).toBe("needs.plan.outputs.mode == 'validation'");
  expect(checks.steps.indexOf(fullHost)).toBeLessThan(
    checks.steps.indexOf(allModels),
  );
});

test("the marketplace harness is compiled before the marketplace lifecycle suite", () => {
  const steps = workflow.jobs.tests.steps;
  const harness = steps.findIndex((step) =>
    step.run?.includes("--product MarketplaceHarness"),
  );
  const marketplace = steps.findIndex((step) =>
    step.run?.includes("test-extension-marketplace.mjs"),
  );
  expect(harness).toBeGreaterThan(-1);
  expect(marketplace).toBeGreaterThan(harness);
});

test("a publication superseded by a newer main commit skips instead of failing the run", () => {
  const script = publish.steps.find(
    ({ name }) =>
      name === "Publish immutable extension releases and the signed catalog",
  ).run;
  const runWith = (stderr) => {
    const root = mkdtempSync(join(tmpdir(), "extension-publish-step-"));
    try {
      const bin = join(root, "bin");
      mkdirSync(bin);
      writeFileSync(
        join(bin, "bun"),
        `#!/bin/sh\necho "${stderr}" >&2\nexit 1\n`,
        { mode: 0o755 },
      );
      return spawnSync("bash", ["-c", script], {
        env: { PATH: `${bin}:/usr/bin:/bin`, RUNNER_TEMP: root },
        encoding: "utf8",
      });
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  };
  const superseded = runWith(
    "error: Extension publication superseded: main changed",
  );
  expect(superseded.status).toBe(0);
  expect(superseded.stdout).toContain("::notice");
  expect(
    runWith("error: Extension publication superseded: trusted catalog changed")
      .status,
  ).toBe(1);
  expect(runWith("error: Extension publication failed: music").status).toBe(1);
});
