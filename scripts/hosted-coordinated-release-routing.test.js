import { test } from "bun:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";

const ci = Bun.YAML.parse(readFileSync(".github/workflows/ci.yml", "utf8"));
const github = {
  event_name: "workflow_dispatch",
  repository: "pulkitxm/edith",
  repository_id: "1289153439",
  actor_id: "65671483",
  ref: "refs/heads/main",
  sha: "a".repeat(40),
};
const defaults = Object.fromEntries(
  Object.entries(ci.on.workflow_dispatch.inputs).map(([key, value]) => [
    key,
    value.default,
  ]),
);
const routes = [
  [
    "hosted-native-owner-tests",
    {
      hosted_native_owner_tests_sha: github.sha,
      hosted_native_owner: "attention",
    },
  ],
  ["hosted-native-compile", { hosted_native_compile_sha: github.sha }],
  ["hosted-host-tests", { hosted_host_tests_sha: github.sha }],
  ["hosted-original-shell", { hosted_shell_journey_sha: github.sha }],
  [
    "hosted-managed-views",
    {
      hosted_managed_views_sha: github.sha,
      hosted_managed_artifacts_run: "17",
      hosted_managed_artifacts_sha: "b".repeat(40),
    },
  ],
  ["hosted-sparkle-update", { hosted_sparkle_update_sha: github.sha }],
  [
    "hosted-public-release-verification",
    {
      public_release_validation_sha: github.sha,
      public_release_validation: "synthetic validation request",
    },
  ],
];

test.each(routes)(
  "%s rejects coordinated release conflicts while preserving its dedicated route",
  (name, selected) => {
    const allows = new Function(
      "github",
      "inputs",
      `return Boolean(${ci.jobs[name].if})`,
    );
    const inputs = { ...defaults, ...selected };
    assert.equal(allows(github, inputs), true);
    for (const coordinated_host_release of [
      "synthetic pending host intent",
      "false",
      "{}",
    ])
      assert.equal(
        allows(github, { ...inputs, coordinated_host_release }),
        false,
      );
    assert.equal(
      allows(github, { ...inputs, coordinated_host_release: "" }),
      true,
    );
  },
);

test.each(["companion", "music-player"])(
  "%s preserves ordinary source checks and isolates only coordinated host releases",
  (name) => {
    const allows = new Function(
      "github",
      "inputs",
      "needs",
      `return Boolean(${ci.jobs[name].if})`,
    );
    for (const event_name of ["push", "pull_request", "workflow_dispatch"]) {
      for (const release of [false, true]) {
        for (const coordinated_host_release of [
          "",
          "synthetic closed pending host intent",
        ]) {
          for (const selected of [false, true]) {
            const needs = {
              changes: {
                outputs: {
                  companion: String(selected),
                  workflows: "false",
                  music_player: String(selected),
                },
              },
            };
            const inputs = { ...defaults, release, coordinated_host_release };
            const coordinated =
              event_name === "workflow_dispatch" &&
              release &&
              coordinated_host_release !== "";
            assert.equal(
              allows({ ...github, event_name }, inputs, needs),
              selected && !coordinated,
            );
            if (name === "companion") {
              needs.changes.outputs.companion = "false";
              needs.changes.outputs.workflows = String(selected);
              assert.equal(
                allows({ ...github, event_name }, inputs, needs),
                selected && !coordinated,
              );
            }
          }
        }
      }
    }
  },
);

test("host-only dispatch keeps ordinary job bodies and all host qualification unchanged", () => {
  const original = Bun.YAML.parse(
    execFileSync("git", ["show", "HEAD:.github/workflows/ci.yml"], {
      encoding: "utf8",
    }),
  );
  for (const name of Object.keys(original.jobs)) {
    if (!["companion", "music-player"].includes(name)) {
      assert.deepEqual(ci.jobs[name], original.jobs[name]);
      continue;
    }
    const before = { ...original.jobs[name] },
      after = { ...ci.jobs[name] };
    delete before.if;
    delete after.if;
    assert.deepEqual(after, before);
  }
  assert.equal(
    readFileSync(".github/workflows/extensions.yml", "utf8"),
    execFileSync("git", ["show", "HEAD:.github/workflows/extensions.yml"], {
      encoding: "utf8",
    }),
  );
  assert(
    ci.jobs.version.steps.some(
      (step) =>
        step.name === "Validate coordinated host release dispatch" &&
        step.if === "inputs.coordinated_host_release != ''" &&
        step.run.includes("production-host-dispatch.mjs"),
    ),
  );
});
