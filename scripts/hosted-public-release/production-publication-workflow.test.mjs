import { test } from "bun:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const expression = (name) => ["$", "{{ ", name, " }}"].join("");
const workflow = readFileSync(".github/workflows/extensions.yml", "utf8");
const coordinator = readFileSync(
  "scripts/hosted-public-release/production-publication-coordinator.mjs",
  "utf8",
);
const runner = readFileSync(
  "scripts/hosted-public-release/production-coordinated-runner.mjs",
  "utf8",
);

test("optional cohort reuses existing native-qualified publish owner and keeps the ordinary complete route", () => {
  const publish = workflow.slice(workflow.indexOf("\n  publish:\n"));
  assert(publish.includes("contents: read"));
  assert(
    publish.includes(`GH_TOKEN: "${expression("secrets.RELEASE_PUSH_TOKEN")}"`),
  );
  assert(publish.includes(`GITHUB_TOKEN: "${expression("github.token")}"`));
  assert(
    publish.includes(
      `EXTENSION_CATALOG_PRIVATE_KEY: "${expression("secrets.EXTENSION_CATALOG_PRIVATE_KEY")}"`,
    ),
  );
  assert(publish.includes("needs.tests.result == 'success'"));
  assert(publish.includes("needs.build.result == 'success'"));
  assert(publish.includes("github.ref == 'refs/heads/main'"));
  const frozenHost = workflow.slice(
    workflow.indexOf("\n  frozen-host:\n"),
    workflow.indexOf("\n  plan:\n"),
  );
  assert(frozenHost.includes("github.repository_id == '1289153439'"));
  assert(frozenHost.includes("github.actor_id == '65671483'"));
  assert(frozenHost.includes("github.actor_id == '320458784'"));
  assert(
    frozenHost.includes(
      "fromJSON(inputs.production_cohort).source == github.sha",
    ),
  );
  assert(
    coordinator.includes(
      'assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID))',
    ),
  );
  assert(publish.includes('if [ -n "$PUBLIC_HOST_UPDATE_REQUEST" ]; then'));
  assert(
    publish.includes(
      "bun scripts/hosted-public-release/production-publication-coordinator.mjs",
    ),
  );
  assert(
    publish.includes("else\n            bun scripts/extension-publish.mjs"),
  );
  assert(
    publish.indexOf("bun scripts/extension-native-evidence.mjs") <
      publish.indexOf("production-publication-coordinator.mjs"),
  );
  assert(publish.includes("inputs.production_cohort != '' && 180 || 360"));
});

test("real restoration is reported through inherited pipes only and public summaries exclude the raw receipt", () => {
  assert(runner.includes("inheritedProductionCatalogChannel()"));
  assert(runner.includes('productionCatalogMessage("host-restored", binding)'));
  assert(runner.includes("validateProductionCatalogMessage("));
  assert(
    coordinator.includes(
      'stdio: ["ignore", "inherit", "inherit", "pipe", "pipe"]',
    ),
  );
  assert.match(
    coordinator,
    /await publication\.promoteStagedExtensionPublication\(\s*stage\.catalogStage\s*,?\s*\)/,
  );
  const summary = workflow.slice(
    workflow.indexOf(
      "      - name: Emit only bounded sanitized public observations",
    ),
  );
  assert(
    summary.includes(`EXPECTED_SOURCE_SHA: "${expression("github.sha")}"`),
  );
  assert(workflow.includes("path: local/public-host-cohort/summary.json"));
  assert(
    !workflow.includes("path: local/public-host-cohort/execution-result.json"),
  );
  assert(!workflow.includes("path: local/public-host-cohort/\n"));
});

test("pending readiness executes actual completed-host and shared-budget contracts in the existing publication job", () => {
  const publish = Bun.YAML.parse(workflow).jobs.publish;
  const validation = publish.steps.find(
    (step) =>
      step.name === "Verify closed public update coordination contracts",
  );
  for (const suite of [
    "production-bootstrap",
    "production-host-readiness",
    "production-completed-host",
    "production-publication-budget",
    "production-pending-cohort",
  ])
    assert(
      validation.run.includes(
        `scripts/hosted-public-release/${suite}.test.mjs`,
      ),
    );
  const prepare = coordinator.indexOf(
    "bootstrap = await preparePendingProductionCohort",
  );
  const stage = coordinator.indexOf(
    "const stage = await publication.publishExtensions",
  );
  const readiness = coordinator.indexOf(
    "await publication.publishStagedHostReadiness",
  );
  const complete = coordinator.indexOf(
    "const completed = await completePendingProductionCohort",
  );
  const bind = coordinator.indexOf(
    "await publication.bindStagedHostContinuation",
  );
  const measure = coordinator.indexOf('"measure-package"');
  const observer = coordinator.indexOf(
    "await runObserver(text, binding, remaining)",
  );
  assert(
    prepare > 0 &&
      prepare < stage &&
      stage < readiness &&
      readiness < complete &&
      complete < bind &&
      bind < measure &&
      measure < observer,
  );
  assert(coordinator.indexOf("await previous.catalog()") < stage);
  assert(coordinator.includes("retireHostBootstrapIntent(bootstrap.pending)"));
});
