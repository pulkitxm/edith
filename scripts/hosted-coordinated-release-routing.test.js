import { test } from "bun:test";
import assert from "node:assert/strict";
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
