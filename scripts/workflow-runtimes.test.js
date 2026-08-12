import { expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";

const expectedActions = new Map([
  ["actions/cache", "v6"],
  ["actions/checkout", "v7"],
  ["actions/configure-pages", "v6"],
  ["actions/deploy-pages", "v5"],
  ["actions/download-artifact", "v8"],
  ["actions/setup-node", "v7"],
  ["actions/setup-go", "v7"],
  ["actions/upload-artifact", "v7"],
  ["actions/upload-pages-artifact", "v5"],
  ["oven-sh/setup-bun", "v2"],
]);

const workflows = readdirSync(".github/workflows")
  .filter((name) => /\.ya?ml$/.test(name))
  .map((name) => ({
    name,
    text: readFileSync(`.github/workflows/${name}`, "utf8"),
  }));

test("workflow actions use current stable majors", () => {
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

test("Linux workflows use the current stable Swift container", () => {
  const ci = workflows.find(({ name }) => name === "ci.yml")?.text;
  const release = workflows.find(({ name }) => name === "release.yml")?.text;
  const ubuntuDevelopment = readFileSync("docs/ubuntu-development.md", "utf8");
  expect(ci).toContain("container: swift:6.3.3-noble");
  expect(release).toContain("container: swift:6.3.3-noble");
  expect(ubuntuDevelopment).toContain("swiftly install 6.3.3");
  expect(ubuntuDevelopment).toContain("swiftly use 6.3.3");
  expect(ubuntuDevelopment).not.toContain("6.3.2");
});

test("workflow validation uses current stable tooling", () => {
  const ci = workflows.find(({ name }) => name === "ci.yml")?.text;
  expect(ci).toContain('go-version: "1.26.x"');
  expect(ci).toContain("github.com/rhysd/actionlint/cmd/actionlint@v1.7.12");
});
