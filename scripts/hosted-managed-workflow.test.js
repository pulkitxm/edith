import { expect, test } from "bun:test";
import { readFile } from "node:fs/promises";

const ci = await readFile(".github/workflows/ci.yml", "utf8");
const workflow = await readFile(
  ".github/workflows/hosted-managed-views.yml",
  "utf8",
);
const route = ci.split("  hosted-managed-views:\n")[1].split("  changes:\n")[0];
const routeAllows = new Function(
  "github",
  "inputs",
  `return Boolean(${route.match(/ {4}if: ([^\n]+)/)[1]})`,
);
const calledAllows = new Function(
  "github",
  "inputs",
  `return Boolean(${workflow.match(/ {4}if: ([^\n]+)/)[1]})`,
);
const github = {
  repository: "pulkitxm/edith",
  event_name: "workflow_dispatch",
  actor_id: "65671483",
  ref: "refs/heads/feat/hosted-managed-view-execution",
  sha: "a".repeat(40),
};
const inputs = {
  hosted_sparkle_update_sha: "",
  public_release_validation_sha: "",
  public_release_validation: "",
