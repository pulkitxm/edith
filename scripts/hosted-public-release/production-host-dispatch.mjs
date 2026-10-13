import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { productionReadonlyEnvironment } from "./production-catalog-channel.mjs";

export function validateHostReleaseDispatch(text, inputs, environment) {
  assert(
    typeof text === "string" &&
      text.length > 0 &&
      Buffer.byteLength(text) <= 65536,
  );
  assert(inputs && typeof inputs === "object" && !Array.isArray(inputs));
  assert.equal(inputs.coordinated_host_release, text);
  assert.equal(inputs.release, true);
  assert.equal(inputs.rebuild, "");
  for (const [key, value] of Object.entries(inputs))
    if (!["coordinated_host_release", "release", "rebuild"].includes(key))
      assert.equal(value, "");
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "Linux",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    PUBLIC_RELEASE_VERIFICATION: "1",
  }))
    assert.equal(environment[key], value);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert.match(environment.GITHUB_SHA, /^[a-f0-9]{40}$/);
  for (const key of [
    "NODE_OPTIONS",
    "NODE_PATH",
    "PYTHONPATH",
    "PYTHONHOME",
    "CFFIXED_USER_HOME",
    "SSH_AUTH_SOCK",
  ])
    assert.equal(environment[key], undefined);
  assert(!Object.keys(environment).some((key) => key.startsWith("EDITH_")));
  const template = JSON.parse(
    execFileSync(
      "python3",
      [
        "-I",
        "-B",
        "-c",
        "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.bootstrap_template(sys.stdin.read())))",
        fileURLToPath(new URL("./production-cohort.py", import.meta.url)),
      ],
      {
        input: text,
        env: productionReadonlyEnvironment(environment),
        timeout: 60000,
        maxBuffer: 65536,
      },
    ).toString(),
  );
  assert.equal(template.source, environment.GITHUB_SHA);
  assert.equal(template.hosts.current.run, null);
  assert.equal(template.hosts.current.runAttempt, null);
  return template;
}

export function verifyCoordinatedHostSource(root, source) {
  assert.match(source, /^[a-f0-9]{40}$/);
  assert.equal(
    execFileSync("git", ["rev-parse", "HEAD"], {
      cwd: root,
      encoding: "utf8",
      timeout: 60000,
    }).trim(),
    source,
  );
  assert.equal(
    execFileSync("git", ["status", "--porcelain", "--untracked-files=normal"], {
      cwd: root,
      encoding: "utf8",
      timeout: 60000,
    }).trim(),
    "",
  );
}

if (import.meta.main || process.argv[1] === fileURLToPath(import.meta.url)) {
  assert.equal(process.argv.length, 2);
  validateHostReleaseDispatch(
    process.env.COORDINATED_HOST_RELEASE,
    JSON.parse(process.env.COORDINATED_RELEASE_INPUTS),
    process.env,
  );
}
