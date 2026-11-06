import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { readinessRequest } from "./extension-release-ready.mjs";
import {
  publicReadExecute,
  rateLimitRetries,
  readGitHubResponse,
  retryDelaySeconds,
  secondaryRateLimitWaitMs,
  TransientGitHubError,
  withGitHubRetry,
  withGitHubRetrySync,
} from "./github-retry.mjs";
import { assetNames, fixture } from "./host-release-test-fixture.mjs";
import { publishExtensionAssets } from "./immutable-release-assets.mjs";
import { publishHostReleaseWithRecovery } from "./publish-host-release.mjs";
import {
  executeReleaseMutation,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";

const repository = "synthetic/fixture";
const tag = "v9.9.9";
const target = "a".repeat(40);

const secondaryLimit = () =>
  Object.assign(new Error("Command failed: gh api"), {
    stderr:
      "gh: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (HTTP 403)\n",
  });

const recorder = () => {
  const delays = [];
  return { delays, sleep: (delay) => delays.push(delay) };
};

test("a secondary rate limit waits at least a minute and retries only the limited call", () => {
  const { delays, sleep } = recorder();
  let calls = 0;
  const result = withGitHubRetrySync(
    () => {
      calls++;
      if (calls === 1) throw secondaryLimit();
      return "read";
    },
    { sleep, probe: () => null, random: () => 0 },
  );
  expect(result).toBe("read");
  expect(calls).toBe(2);
  expect(delays).toEqual([secondaryRateLimitWaitMs]);
});

test("an exhausted core limit waits for the probed reset", () => {
  const { delays, sleep } = recorder();
  let calls = 0;
  withGitHubRetrySync(
    () => {
      if (++calls === 1)
        throw Object.assign(new Error("Command failed"), {
          stderr: "gh: API rate limit exceeded for user ID 1. (HTTP 403)",
        });
    },
    { sleep, probe: () => 400_000 },
  );
  expect(delays).toEqual([400_000]);
});

test("rate limit retries back off exponentially and stay bounded", () => {
  const { delays, sleep } = recorder();
  let calls = 0;
  expect(() =>
    withGitHubRetrySync(
      () => {
        calls++;
        throw secondaryLimit();
      },
      { sleep, probe: () => null, random: () => 0 },
    ),
  ).toThrow("Command failed");
  expect(calls).toBe(rateLimitRetries + 1);
  expect(delays).toEqual([
    secondaryRateLimitWaitMs,
    2 * secondaryRateLimitWaitMs,
    4 * secondaryRateLimitWaitMs,
  ]);
});

test("Retry-After beyond thirty seconds is honored for 5xx and 429 responses", async () => {
  for (const status of [503, 429]) {
    const { delays, sleep } = recorder();
    let calls = 0;
    const response = await readGitHubResponse(
      async () => {
        calls++;
        if (calls === 1)
          return new Response("", {
            status,
            headers: { "retry-after": "120" },
          });
        return new Response("{}", { status: 200 });
      },
      "https://api.github.com/repos/synthetic/fixture",
      () => undefined,
      { sleep, probe: () => null },
    );
    expect(response.status).toBe(200);
    expect(delays).toEqual([120_000]);
  }
});

test("a rate limited 403 waits until x-ratelimit-reset before reading again", async () => {
  const { delays, sleep } = recorder();
  const now = Date.now();
  let calls = 0;
  const value = await readGitHubResponse(
    async () => {
      calls++;
      if (calls === 1)
        return new Response('{"message":"API rate limit exceeded"}', {
          status: 403,
          headers: {
            "x-ratelimit-remaining": "0",
            "x-ratelimit-reset": String(Math.ceil(now / 1000) + 90),
          },
        });
      return new Response('{"ok":true}', { status: 200 });
    },
    "https://api.github.com/repos/synthetic/fixture",
    () => undefined,
    {
      sleep,
      probe: () => {
        throw new Error("headers already carry the reset");
      },
      read: (response) => response.json(),
    },
  );
  expect(value).toEqual({ ok: true });
  expect(delays).toHaveLength(1);
  expect(delays[0]).toBeGreaterThan(85_000);
  expect(delays[0]).toBeLessThanOrEqual(92_000);
});

test("a permission 403 without rate limit signals is not retried", async () => {
  const { delays, sleep } = recorder();
  const response = await readGitHubResponse(
    async () =>
      new Response('{"message":"Resource not accessible"}', { status: 403 }),
    "https://api.github.com/repos/synthetic/fixture",
    () => undefined,
    { sleep },
  );
  expect(response.status).toBe(403);
  expect(await response.json()).toEqual({ message: "Resource not accessible" });
  expect(delays).toEqual([]);
});

test("a wrapped download failure keeps its rate limit classification", async () => {
  const { delays, sleep } = recorder();
  let calls = 0;
  await withGitHubRetry(
    async () => {
      if (++calls === 1)
        throw new TransientGitHubError("Release asset download failed", {
          cause: secondaryLimit(),
        });
    },
    { sleep, probe: () => null, random: () => 0 },
  );
  expect(delays).toEqual([secondaryRateLimitWaitMs]);
});

test("a landed write is confirmed after the wait instead of during the limit", () => {
  const events = [];
  const result = executeReleaseMutation(
    [
      "release",
      "create",
      tag,
      "--target",
      target,
      "--draft",
      "--repo",
      repository,
    ],
    {
      execute: (command, args) => {
        if (command === "pukbot") {
          events.push("mutation");
          throw Object.assign(new Error("Command failed: pukbot"), {
            stdout: JSON.stringify({
              ok: false,
              error: {
                message:
                  "failed to inspect the Pukbot workflow run: API rate limit exceeded for user ID 1 (HTTP 403)",
              },
            }),
          });
        }
        if (args[1] === "rate_limit") return "4990 0";
        events.push("confirm");
        return JSON.stringify({
          id: 4,
          tag_name: tag,
          target_commitish: target,
          draft: true,
          prerelease: false,
          assets: [],
        });
      },
      retry: { sleep: () => events.push("wait"), random: () => 0 },
    },
  );
  expect(result).toEqual({ ok: true, confirmed: true });
  expect(events).toEqual(["mutation", "wait", "confirm"]);
});

test("a landed release promotion is confirmed instead of dispatched again", () => {
  let mutations = 0;
  let draft = true;
  const result = executeReleaseMutation(
    [
      "release",
      "edit",
      "4",
      "--tag",
      tag,
      "--draft",
      "false",
      "--prerelease",
      "false",
      "--repo",
      repository,
    ],
    {
      execute: (command, args) => {
        if (command === "pukbot") {
          mutations++;
          draft = false;
          throw secondaryLimit();
        }
        if (args[1] === "rate_limit") return "4990 0";
        return JSON.stringify({
          id: 4,
          tag_name: tag,
          draft,
          prerelease: false,
          assets: [],
        });
      },
      retry: { sleep: () => {} },
    },
  );
  expect(result).toEqual({ ok: true, confirmed: true });
  expect(mutations).toBe(1);
});

test("workflow completion is read once instead of watched with repeated polling", () => {
  const calls = [];
  executeReleaseMutation(["release", "edit", "--repo", repository, "4"], {
    execute: (command, args) => {
      calls.push([command, ...args]);
      if (command === "pukbot")
        return JSON.stringify({
          workflowUrl: "https://github.com/synthetic/control/actions/runs/77",
        });
      return JSON.stringify({ status: "completed", conclusion: "success" });
    },
  });
  expect(calls.filter(([command]) => command === "gh")).toEqual([
    ["gh", "api", "repos/synthetic/control/actions/runs/77"],
  ]);
});

test("an interrupted upload that leaves a starter asset is discarded and uploaded again", async () => {
  const directory = mkdtempSync(join(tmpdir(), "rate-limit-upload-"));
  try {
    const file = join(directory, "package.json");
    writeFileSync(file, "payload");
    const release = { id: 4, tag_name: tag, draft: true, assets: [] };
    const events = [];
    const result = await uploadReleaseAsset({
      repository,
      releaseID: 4,
      tag,
      file,
      retry: { sleep: () => {} },
      execute: (command, args) => {
        if (command === "pukbot") {
          events.push("upload");
          if (release.assets.some((asset) => asset.name === "package.json"))
            throw Object.assign(new Error("Command failed"), {
              stderr: "HTTP 422: Validation Failed: already_exists",
            });
          if (events.length === 1) {
            release.assets.push({
              id: 30,
              name: "package.json",
              size: 7,
              state: "starter",
            });
            throw Object.assign(new Error("Command failed"), {
              stderr: "HTTP 502 Bad Gateway",
            });
          }
          release.assets.push({
            id: 31,
            name: "package.json",
            size: 7,
            state: "uploaded",
          });
          return "{}";
        }
        if (args.includes("DELETE")) {
          events.push(`delete ${args.at(-1)}`);
          release.assets = release.assets.filter((asset) => asset.id !== 30);
          return "";
        }
        return JSON.stringify(release);
      },
    });
    expect(result).toBe("pukbot");
    expect(events).toEqual([
      "upload",
      `delete repos/${repository}/releases/assets/30`,
      "upload",
    ]);
    expect(release.assets).toEqual([
      { id: 31, name: "package.json", size: 7, state: "uploaded" },
    ]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

function withDeletes(value) {
  const deletes = [];
  const execute = (command, args, options) => {
    if (command === "gh" && args.includes("DELETE")) {
      const id = Number(args.at(-1).split("/").at(-1));
      deletes.push(id);
      value.release.assets = value.release.assets.filter(
        (asset) => asset.id !== id,
      );
      return "";
    }
    return value.execute(command, args, options);
  };
  return { deletes, execute };
}

test("a host release rerun after a partial publish discards the broken asset and finishes", async () => {
  const value = fixture(true);
  try {
    value.release.assets.push(value.asset("appcast.xml", 50), {
      id: 51,
      name: "Edith.dmg",
      size: 50_000,
      state: "starter",
    });
    const github = withDeletes(value);
    const result = await publishHostReleaseWithRecovery({
      directory: value.directory,
      repository,
      tag: "v1.2.3",
      target,
      execute: github.execute,
      matchesAsset: value.matchesAsset,
      rateLimit: { sleep: () => {} },
      retry: { sleep: () => {} },
    });
    expect(result).toEqual({ tag: "v1.2.3", assets: assetNames });
    expect(github.deletes).toEqual([51]);
    expect(value.release.draft).toBe(false);
    expect(value.release.assets.map(({ name }) => name).sort()).toEqual(
      [...assetNames].sort(),
    );
    expect(
      value.release.assets.every((asset) => asset.state === "uploaded"),
    ).toBe(true);
  } finally {
    value.clean();
  }
});

const isRemote = (command, args) =>
  (command === "gh" && args[0] === "api" && args[1] !== "rate_limit") ||
  (command === "pukbot" && !args.includes("--dry-run"));

function countingGitHub(value, failAt) {
  let remote = 0;
  const waits = [];
  const execute = (command, args, options) => {
    if (command === "gh" && args[1] === "rate_limit") return "4990 0";
    if (isRemote(command, args) && ++remote === failAt) throw secondaryLimit();
    return value.execute(command, args, options);
  };
  const sleep = (milliseconds) => waits.push(milliseconds);
  return {
    waits,
    get remote() {
      return remote;
    },
    publish: () =>
      publishHostReleaseWithRecovery({
        directory: value.directory,
        repository,
        tag: "v1.2.3",
        target,
        execute,
        matchesAsset: value.matchesAsset,
        rateLimit: { sleep },
        retry: { sleep, random: () => 0 },
      }),
  };
}

test("a secondary limit during host publication retries one call instead of restarting the publication", async () => {
  const clean = fixture();
  let total;
  try {
    const github = countingGitHub(clean, 0);
    await github.publish();
    total = github.remote;
  } finally {
    clean.clean();
  }
  for (const failAt of [3, Math.floor(total / 2), total - 2]) {
    const value = fixture();
    try {
      const github = countingGitHub(value, failAt);
      await github.publish();
      expect(github.waits).toEqual([secondaryRateLimitWaitMs]);
      expect(github.remote).toBe(total + 1);
      expect(value.release.draft).toBe(false);
    } finally {
      value.clean();
    }
  }
});

test("an extension draft rerun discards an incomplete asset before uploading it again", async () => {
  const directory = mkdtempSync(join(tmpdir(), "extension-incomplete-"));
  try {
    const file = join(directory, "keepAwake.zip");
    writeFileSync(file, "synthetic package");
    const item = {
      id: 9,
      tag_name: "fixture",
      draft: true,
      assets: [{ id: 3, name: "keepAwake.zip", size: 17, state: "starter" }],
    };
    const discarded = [];
    const remote = new Map();
    await publishExtensionAssets({
      repository,
      item,
      entry: { tag: "fixture" },
      files: [[file, "keepAwake.zip"]],
      readRelease: () => ({ ...item, assets: [...item.assets] }),
      discardAsset: (_, asset) => {
        discarded.push(asset.id);
        item.assets = item.assets.filter(({ id }) => id !== asset.id);
      },
      uploadAsset: async (_, __, ___, path, name) => {
        const bytes = readFileSync(path);
        remote.set(name, bytes);
        item.assets.push({
          id: 4,
          name,
          size: bytes.length,
          state: "uploaded",
        });
      },
      downloadAsset: async ({ asset }) => ({
        sha256: createHash("sha256")
          .update(remote.get(asset.name))
          .digest("hex"),
      }),
    });
    expect(discarded).toEqual([3]);
    expect(item.assets.map(({ id }) => id)).toEqual([4]);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("public ref and commit reads use the workflow token and everything else keeps the release token", () => {
  const seen = [];
  const execute = publicReadExecute(
    (_command, args, options) => {
      seen.push([args.join(" "), options.env?.GH_TOKEN]);
      return "{}";
    },
    { GH_TOKEN: "release-token", GITHUB_TOKEN: "workflow-token" },
  );
  for (const args of [
    ["api", "repos/synthetic/fixture/git/ref/heads/main"],
    ["api", "repos/synthetic/fixture/git/ref/tags/v1.2.3"],
    ["api", `repos/synthetic/fixture/git/tags/${"b".repeat(40)}`],
    ["api", `https://api.github.com/repos/synthetic/fixture/commits/${target}`],
    ["api", "repos/synthetic/fixture/releases/tags/v1.2.3"],
    ["api", "repos/synthetic/fixture/releases?per_page=100&page=1"],
    ["api", "--method", "DELETE", "repos/synthetic/fixture/releases/assets/3"],
    ["api", "rate_limit"],
  ])
    execute("gh", args, {});
  expect(seen.map(([, token]) => token)).toEqual([
    "workflow-token",
    "workflow-token",
    "workflow-token",
    "workflow-token",
    undefined,
    undefined,
    undefined,
    undefined,
  ]);
  const passthrough = () => "unchanged";
  expect(publicReadExecute(passthrough, { GH_TOKEN: "release-token" })).toBe(
    passthrough,
  );
});

test("release readiness reads GitHub with the workflow token", async () => {
  const headers = [];
  const request = readinessRequest({
    environment: { GH_TOKEN: "release-token", GITHUB_TOKEN: "workflow-token" },
    fetch_: async (_, init) => {
      headers.push(init.headers.Authorization);
      return new Response("{}");
    },
  });
  await request(
    "https://api.github.com/repos/synthetic/fixture/git/ref/heads/main",
  );
  await request("https://github.com/synthetic/fixture/releases/download/x/y");
  expect(headers).toEqual(["Bearer workflow-token", undefined]);
});

test("shell retry delays use the shared rate limit classification", () => {
  const directory = mkdtempSync(join(tmpdir(), "retry-delay-"));
  try {
    const limited = join(directory, "limited");
    const transient = join(directory, "transient");
    writeFileSync(
      limited,
      '{"ok":false,"error":{"message":"API rate limit exceeded for user ID 1"}}',
    );
    writeFileSync(transient, "HTTP 502 Bad Gateway");
    const delay = (attempt, file) =>
      execFileSync(
        process.execPath,
        [
          resolve("scripts/github-retry.mjs"),
          "delay",
          attempt,
          "15",
          "65",
          file,
        ],
        { encoding: "utf8" },
      ).trim();
    expect(delay("1", limited)).toBe("65");
    expect(delay("3", limited)).toBe("260");
    expect(delay("2", transient)).toBe("30");
    expect(
      retryDelaySeconds({
        attempt: 9,
        transientSeconds: 15,
        rateLimitSeconds: 65,
        failure: "secondary rate limit",
      }),
    ).toBe(300);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

const gitVariables = Object.keys(process.env).filter((name) =>
  name.startsWith("GIT_"),
);

function gitIn(cwd, ...args) {
  const env = { ...process.env };
  for (const name of gitVariables) delete env[name];
  return execFileSync("git", args, { cwd, env, encoding: "utf8" }).trim();
}

function commit(cwd, path, message) {
  mkdirSync(join(cwd, path, ".."), { recursive: true });
  writeFileSync(join(cwd, path), `${message}\n`);
  gitIn(cwd, "add", path);
  gitIn(
    cwd,
    "-c",
    "user.name=Release Test",
    "-c",
    "user.email=release@example.com",
    "-c",
    "commit.gpgsign=false",
    "commit",
    "-q",
    "-m",
    message,
  );
  return gitIn(cwd, "rev-parse", "HEAD");
}

function mainPushAreas(cwd, before) {
  const workflow = Bun.YAML.parse(
    readFileSync(".github/workflows/ci.yml", "utf8"),
  );
  const script = workflow.jobs.changes.steps.find(
    (step) => step.id === "areas",
  ).run;
  const output = join(cwd, "..", "output");
  rmSync(output, { force: true });
  const env = {
    ...process.env,
    BASE_REF: "",
    BEFORE: before,
    GITHUB_EVENT_NAME: "push",
    GITHUB_REF: "refs/heads/main",
    GITHUB_OUTPUT: output,
  };
  for (const name of gitVariables) delete env[name];
  execFileSync(
    "bash",
    [
      "-e",
      "-o",
      "pipefail",
      "-c",
      script.slice(0, script.indexOf("test_scope=()")),
    ],
    { cwd, env, stdio: "pipe" },
  );
  return Object.fromEntries(
    readFileSync(output, "utf8")
      .trim()
      .split("\n")
      .map((line) => line.split("=")),
  );
}

test("a main push releases host changes that a superseded build left unreleased", () => {
  const root = mkdtempSync(join(tmpdir(), "edith-unreleased-host-"));
  try {
    const checkout = join(root, "checkout");
    mkdirSync(checkout);
    gitIn(checkout, "init", "-q", "--initial-branch=main");
    commit(checkout, "README.md", "Initial source");
    gitIn(checkout, "tag", "v1.0.0");
    const host = commit(
      checkout,
      "Packages/EdithHost/Sources/EdithHost/Synthetic.swift",
      "Host change",
    );
    commit(checkout, "docs/synthetic.md", "Docs change");
    const unreleased = mainPushAreas(checkout, host);
    expect(unreleased.host).toBe("true");
    expect(unreleased.docs).toBe("true");
    expect(unreleased.swift).toBe("false");
    gitIn(checkout, "tag", "v1.0.1", host);
    expect(mainPushAreas(checkout, host).host).toBe("false");
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
