import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  configureManagedUITestRun,
  managedRunnerEnvironment,
  writeManagedUIProject,
} from "./hosted-managed-views/ui-project.mjs";

const source = "a".repeat(40);
const environment = {
  GITHUB_ACTIONS: "true",
  RUNNER_OS: "macOS",
  RUNNER_ENVIRONMENT: "github-hosted",
  GITHUB_REPOSITORY: "pulkitxm/edith",
  GITHUB_ACTOR_ID: "65671483",
  GITHUB_EVENT_NAME: "workflow_dispatch",
  GITHUB_REF: "refs/heads/feat/hosted-managed-view-execution",
  GITHUB_SHA: source,
  EXPECTED_SOURCE_SHA: source,
  EDITH_HOSTED_MANAGED_VIEWS: "1",
  PUBLISH: "false",
  REBUILD: "",
};

test("actual generated UI plan preserves runner account HOME, fixed source and bounded one-target execution", async () => {
  const directory = await realpath(
    await mkdtemp(join(tmpdir(), "edith-managed-ui-project-")),
  );
  try {
    const fixture = {
      directory,
      identifier:
        "com.pulkit.edith.tests.worker-00000000-0000-4000-8000-000000000001",
      sourceCommit: source,
    };
    const variables = managedRunnerEnvironment(
      { ...environment, HOME: "/account", token: "never-copy" },
      fixture,
    );
    expect(variables).not.toHaveProperty("HOME");
    expect(variables).not.toHaveProperty("token");
    const project = await writeManagedUIProject(directory, variables);
    const text = await readFile(join(project, "project.pbxproj"), "utf8");
    expect(text).toContain("HostedManagedApprovalUITests.swift");
    expect(text).toContain("HostedManagedApprovalContract.swift");
    expect(text).not.toContain("OriginalShellJourneyTests.swift");
    const plan = join(directory, "tests.xctestrun");
    execFileSync("python3", [
      "-c",
      "import plistlib,sys;plistlib.dump({'__xctestrun_metadata__':{'FormatVersion':1},'HostedManagedApproval':{'IsUITestBundle':True,'UseUITargetAppProvidedByTests':True}},open(sys.argv[1],'wb'))",
      plan,
    ]);
    configureManagedUITestRun(plan, variables);
    const configured = JSON.parse(
      execFileSync("python3", [
        "-c",
        "import plistlib,json,sys;print(json.dumps(plistlib.load(open(sys.argv[1],'rb'))))",
        plan,
      ]),
    );
    expect(configured.HostedManagedApproval.EnvironmentVariables).toEqual(
      variables,
    );
    expect(
      configured.HostedManagedApproval.MaximumTestExecutionTimeAllowance,
    ).toBe(240);
    await expect(
      writeManagedUIProject(directory, { ...variables, HOME: "/account" }),
    ).rejects.toThrow();
    execFileSync("python3", [
      "-c",
      "import plistlib,sys; p=sys.argv[1];v=plistlib.load(open(p,'rb'));v['HostedManagedApproval']['EnvironmentVariables']['CFFIXED_USER_HOME']='/account';plistlib.dump(v,open(p,'wb'))",
      plan,
    ]);
    expect(() => configureManagedUITestRun(plan, variables)).toThrow();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
