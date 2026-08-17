import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";

const expectedActions = new Map([
  [
    "DavidAnson/markdownlint-cli2-action",
    "21c1be1b93ad9ed58fa840aacc3f279cde2a72ff",
  ],
  ["actions/cache", "55cc8345863c7cc4c66a329aec7e433d2d1c52a9"],
  ["actions/checkout", "3d3c42e5aac5ba805825da76410c181273ba90b1"],
  ["actions/configure-pages", "45bfe0192ca1faeb007ade9deae92b16b8254a0d"],
  [
    "actions/dependency-review-action",
    "a1d282b36b6f3519aa1f3fc636f609c47dddb294",
  ],
  ["actions/deploy-pages", "cd2ce8fcbc39b97be8ca5fce6e763baed58fa128"],
  ["actions/download-artifact", "3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c"],
  ["actions/labeler", "bf12e9b00b37c5c0ca2b87b79b2daf7891dbda13"],
  ["actions/setup-go", "b7ad1dad31e06c5925ef5d2fc7ad053ef454303e"],
  ["actions/setup-node", "820762786026740c76f36085b0efc47a31fe5020"],
  ["actions/stale", "4391f3da665fdf50b6810c1a66712fb9ba21aa93"],
  ["actions/upload-artifact", "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a"],
  ["actions/upload-pages-artifact", "fc324d3547104276b827a68afc52ff2a11cc49c9"],
  [
    "amannn/action-semantic-pull-request",
    "48f256284bd46cdaab1048c3721360e808335d50",
  ],
  ["aquasecurity/trivy-action", "ed142fd0673e97e23eac54620cfb913e5ce36c25"],
  [
    "github/codeql-action/upload-sarif",
    "ff2f1c621b7f889edc0d3c761ac2e6a3f8cdb0dd",
  ],
  ["gitleaks/gitleaks-action", "e0c47f4f8be36e29cdc102c57e68cb5cbf0e8d1e"],
  ["lycheeverse/lychee-action", "e7477775783ea5526144ba13e8db5eec57747ce8"],
  ["ossf/scorecard-action", "2d1146689b8cda280b9bc96326124645441f03bc"],
  ["oven-sh/setup-bun", "0c5077e51419868618aeaa5fe8019c62421857d6"],
  ["pascalgn/size-label-action", "56b489b027932ec0cf60438a1a5f1a19c8fc71ff"],
  ["taiki-e/install-action", "288e746965032cfcc232e09af2daf5f23c14d780"],
]);

const workflows = readdirSync(".github/workflows")
  .filter((name) => /\.ya?ml$/.test(name))
  .map((name) => ({
    name,
    text: readFileSync(`.github/workflows/${name}`, "utf8"),
  }));
const lockfile = readFileSync("bun.lock", "utf8");

test("workflow actions use approved immutable revisions", () => {
  const seen = new Set();
  for (const workflow of workflows) {
    for (const match of workflow.text.matchAll(/uses:\s+([^@\s]+)@([^\s]+)/g)) {
      const [, action, version] = match;
      if (action.startsWith("./")) continue;
      expect(
        expectedActions.has(action),
        `${workflow.name}: ${action}`,
      ).toBeTrue();
      expect(version, `${workflow.name}: ${action}`).toBe(
        expectedActions.get(action),
      );
      seen.add(action);
    }
  }
  for (const action of expectedActions.keys()) {
    expect(seen.has(action), action).toBeTrue();
  }
});

test("workflow validation uses current stable tooling", () => {
  const ci = workflows.find(({ name }) => name === "ci.yml")?.text;
  expect(ci).toContain('go-version: "1.26.x"');
  expect(ci).toContain("github.com/rhysd/actionlint/cmd/actionlint@v1.7.12");
});

test("the lockfile carries Linux workflow executables", () => {
  expect(lockfile).toContain('"lefthook-linux-arm64"');
  expect(lockfile).toContain('"lefthook-linux-x64"');
  expect(lockfile).toContain('"@biomejs/cli-linux-x64"');
});
