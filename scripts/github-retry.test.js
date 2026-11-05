import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  backoffDelay,
  isTransientFailure,
  rateLimitWait,
  secondaryRateLimitWaitMs,
  retryAfterMs,
  withGitHubRetrySync,
  withRateLimitRecovery,
  withRateLimitRecoverySync,
} from "./github-retry.mjs";
import {
  executeReleaseMutation,
  uploadReleaseAsset,
} from "./release-asset-upload.mjs";

const repository = "synthetic/fixture";

function recordingSleep() {
  const delays = [];
  return { delays, sleep: async (delay) => delays.push(delay) };
}

test("422 command failures are never retried", () => {
  const { delays, sleep } = recordingSleep();
  let attempts = 0;
  expect(() =>
    withGitHubRetrySync(
      () => {
        attempts++;
        throw Object.assign(new Error("Command failed"), {
          stderr: "gh: Validation Failed (HTTP 422)",
        });
      },
      { sleep },
    ),
  ).toThrow("Command failed");
  expect(attempts).toBe(1);
  expect(delays).toEqual([]);
});

test("backoff doubles to a 30 second cap and parses Retry-After", () => {
  expect(
    [1, 2, 3, 4, 5, 6, 7].map((attempt) =>
      backoffDelay(attempt, { random: () => 0 }),
    ),
  ).toEqual([1000, 2000, 4000, 8000, 16000, 30000, 30000]);
  expect(backoffDelay(1, { random: () => 0.99 })).toBeLessThan(1250);
  expect(retryAfterMs("3")).toBe(3000);
  expect(retryAfterMs(new Date(61_000).toUTCString(), 1_000)).toBe(60_000);
  expect(isTransientFailure(new Error("unexpected end of JSON input"))).toBe(
    true,
  );
  expect(isTransientFailure(new Error("HTTP 404: Not Found"))).toBe(false);
  expect(
    isTransientFailure(new Error("failed to inspect the Pukbot workflow run")),
  ).toBe(true);
  expect(
    isTransientFailure(new Error("failed to list Pukbot workflow runs")),
  ).toBe(true);
});

const tag = "v9.9.9";
const target = "a".repeat(40);
const createArgs = [
  "release",
  "create",
  tag,
  "--target",
  target,
  "--draft",
  "--generate-notes",
  "--repo",
  repository,
];
const emptyResponse = () =>
  Object.assign(new Error("Command failed: pukbot"), {
    stdout: JSON.stringify({
      ok: false,
      error: { message: "unexpected end of JSON input" },
    }),
  });

test("a failed release create is confirmed by re-reading the release", () => {
  const calls = [];
  const execute = (command, args) => {
    calls.push([command, ...args]);
    if (command === "pukbot") throw emptyResponse();
    return JSON.stringify({
      id: 4,
      tag_name: tag,
      target_commitish: target,
      draft: true,
      prerelease: false,
      assets: [],
    });
  };
  expect(
    executeReleaseMutation(createArgs, {
      execute,
      retry: { sleep: () => {} },
    }),
  ).toEqual({ ok: true, confirmed: true });
  expect(calls.filter(([command]) => command === "pukbot")).toHaveLength(1);
  expect(calls[1]).toEqual([
    "gh",
    "api",
    `repos/${repository}/releases/tags/${tag}`,
  ]);
});

test("an unconfirmed create is retried and a failed workflow counts as transient", () => {
  const events = [];
  const execute = (command, args) => {
    events.push(`${command} ${args[0]}`);
    if (command === "pukbot")
      return JSON.stringify({
        workflowUrl: "https://github.com/synthetic/control/actions/runs/5",
      });
    if (args[0] === "run") {
      if (events.filter((event) => event === "gh run").length === 1)
        throw new Error("exit status 1");
      return "";
    }
    if (args[1].includes("/tags/"))
      throw Object.assign(new Error("Not found"), {
        stderr: "gh: Not Found (HTTP 404)",
      });
    return "[]";
  };
  expect(
    executeReleaseMutation(createArgs, {
      execute,
      retry: { sleep: () => {} },
    }).workflowUrl,
  ).toBe("https://github.com/synthetic/control/actions/runs/5");
  expect(events.filter((event) => event === "pukbot release")).toHaveLength(2);
});

test("a failed tag create is confirmed by the exact tag reference", () => {
  let pukbot = 0;
  const execute = (command, args) => {
    if (command === "pukbot") {
      pukbot++;
      throw new Error("Pukbot workflow failed: HTTP 502");
    }
    expect(args).toEqual(["api", `repos/${repository}/git/ref/tags/${tag}`]);
    return JSON.stringify({
      ref: `refs/tags/${tag}`,
      object: { type: "commit", sha: target },
    });
  };
  expect(
    executeReleaseMutation(
      ["tag", "create", "--repo", repository, "--target", target, tag],
      { execute, retry: { sleep: () => {} } },
    ),
  ).toEqual({ ok: true, confirmed: true });
  expect(pukbot).toBe(1);
});

test("a failed asset upload is confirmed by the uploaded asset", async () => {
  const directory = mkdtempSync(join(tmpdir(), "github-retry-"));
  const file = join(directory, "Edith.dmg");
  writeFileSync(file, "payload");
  let pukbot = 0;
  const execute = (command) => {
    if (command === "pukbot") {
      pukbot++;
      throw Object.assign(new Error("Command failed"), {
        stderr: "HTTP 503 Service Unavailable",
      });
    }
    return JSON.stringify({
      id: 4,
      tag_name: tag,
      draft: true,
      assets: [{ name: "Edith.dmg", size: 7, state: "uploaded" }],
    });
  };
  expect(
    await uploadReleaseAsset({
      repository,
      releaseID: 4,
      tag,
      file,
      execute,
      retry: { sleep: () => {} },
    }),
  ).toBe("pukbot");
  expect(pukbot).toBe(1);
});

test("a 422 release create failure is not retried", () => {
  let pukbot = 0;
  const execute = (command) => {
    if (command === "pukbot") {
      pukbot++;
      throw Object.assign(new Error("Command failed"), {
        stderr: "HTTP 422: Validation Failed",
      });
    }
    throw new Error("unexpected read");
  };
  expect(() =>
    executeReleaseMutation(createArgs, {
      execute,
      retry: { sleep: () => {} },
    }),
  ).toThrow("Command failed");
  expect(pukbot).toBe(1);
});

test("workflow dispatch lookup failures retain normal retry and permission rules", () => {
  for (const message of [
    "could not find the dispatched Pukbot workflow run",
    "GitHub rejected the Pukbot workflow dispatch",
    "failed to resolve the authenticated GitHub user",
  ]) {
    const error = Object.assign(new Error("Command failed: pukbot"), {
      stdout: JSON.stringify({ ok: false, error: { message } }),
    });
    expect(isTransientFailure(error)).toBe(true);
    expect(
      isTransientFailure(
        Object.assign(error, { stderr: "HTTP 403 Forbidden" }),
      ),
    ).toBe(false);
  }
});

test("an unacknowledged release edit retries through the release client", () => {
  let mutations = 0;
  let watches = 0;
  const result = executeReleaseMutation(
    ["release", "edit", "--repo", repository, "4", "--draft", "false"],
    {
      execute: (command) => {
        if (command === "pukbot") {
          mutations++;
          if (mutations === 1) {
            throw Object.assign(new Error("Command failed"), {
              stdout: JSON.stringify({
                ok: false,
                error: {
                  message: "could not find the dispatched Pukbot workflow run",
                },
              }),
            });
          }
          return JSON.stringify({
            workflowUrl: "https://github.com/synthetic/control/actions/runs/8",
          });
        }
        watches++;
        return "";
      },
      retry: { sleep: () => {} },
    },
  );
  expect(result.workflowUrl).toBe(
    "https://github.com/synthetic/control/actions/runs/8",
  );
  expect(mutations).toBe(2);
  expect(watches).toBe(1);
});

test("an upload with a lost dispatch acknowledgement confirms the existing asset", async () => {
  const directory = mkdtempSync(join(tmpdir(), "github-retry-"));
  const file = join(directory, "package.json");
  writeFileSync(file, "payload");
  let mutations = 0;
  const result = await uploadReleaseAsset({
    repository,
    releaseID: 4,
    tag,
    file,
    execute: (command) => {
      if (command === "pukbot") {
        mutations++;
        throw Object.assign(new Error("Command failed"), {
          stdout: JSON.stringify({
            ok: false,
            error: {
              message: "could not find the dispatched Pukbot workflow run",
            },
          }),
        });
      }
      return JSON.stringify({
        id: 4,
        tag_name: tag,
        draft: true,
        assets: [{ name: "package.json", size: 7, state: "uploaded" }],
      });
    },
    retry: { sleep: () => {} },
  });
  expect(result).toBe("pukbot");
  expect(mutations).toBe(1);
});

test("GitHub connection timeouts retry reads without changing the request", () => {
  let calls = 0;
  const failure = Object.assign(new Error("Command failed: gh api"), {
    stderr:
      'Get "https://api.github.com/repos/synthetic/fixture": dial tcp 192.0.2.1:443: connect: operation timed out',
  });
  expect(isTransientFailure(failure)).toBe(true);
  const result = withGitHubRetrySync(
    () => {
      calls++;
      if (calls === 1) throw failure;
      return "verified response";
    },
    { sleep: () => {} },
  );
  expect(result).toBe("verified response");
  expect(calls).toBe(2);
});

test("an exhausted rate limit waits for its reset and a healthy one does not", () => {
  const now = () => 1_000_000;
  const probe = (output) => rateLimitWait({ execute: () => output, now });
  expect(probe("3 1600\n")).toBe(605_000);
  expect(probe("0 900\n")).toBe(5_000);
  expect(probe("0 99999\n")).toBe(65 * 60_000);
  expect(probe("4000 1600\n")).toBeNull();
  expect(probe("garbage")).toBeUndefined();
  expect(
    rateLimitWait({
      execute: () => {
        throw new Error("offline");
      },
      now,
    }),
  ).toBeUndefined();
});

test("a rate-limited operation reruns after the reset, at most twice", () => {
  const { delays, sleep } = recordingSleep();
  let calls = 0;
  const result = withRateLimitRecoverySync(
    () => {
      calls++;
      if (calls < 3)
        throw new Error("GitHub rejected the Pukbot workflow dispatch");
      return "published";
    },
    { probe: () => 61_000, sleep },
  );
  expect(result).toBe("published");
  expect(delays).toEqual([61_000, 61_000]);
  calls = 0;
  expect(() =>
    withRateLimitRecoverySync(
      () => {
        calls++;
        throw new Error("still limited");
      },
      { probe: () => 1_000, sleep: () => {} },
    ),
  ).toThrow("still limited");
  expect(calls).toBe(3);
});

test("failures with a healthy rate limit are rethrown without waiting", async () => {
  const { delays, sleep } = recordingSleep();
  let calls = 0;
  await expect(
    withRateLimitRecovery(
      async () => {
        calls++;
        throw new Error("HTTP 422: Validation Failed");
      },
      { probe: () => null, sleep },
    ),
  ).rejects.toThrow("HTTP 422");
  expect(calls).toBe(1);
  expect(delays).toEqual([]);
});

const secondaryLimitError = () =>
  Object.assign(new Error("Command failed: gh api repos/o/r/releases/1"), {
    stderr:
      "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID SYNTHETIC (HTTP 403)\n",
  });

test("a rate limit error with core quota left waits out the secondary limit, at most twice", async () => {
  const { delays, sleep } = recordingSleep();
  let calls = 0;
  const result = await withRateLimitRecovery(
    async () => {
      calls++;
      if (calls < 3) throw secondaryLimitError();
      return "published";
    },
    { probe: () => null, sleep },
  );
  expect(result).toBe("published");
  expect(delays).toEqual([secondaryRateLimitWaitMs, secondaryRateLimitWaitMs]);
  calls = 0;
  expect(() =>
    withRateLimitRecoverySync(
      () => {
        calls++;
        throw secondaryLimitError();
      },
      { probe: () => null, sleep: () => {} },
    ),
  ).toThrow("Command failed");
  expect(calls).toBe(3);
});

test("a rate limit error with an unreadable quota probe fails closed", () => {
  const { delays, sleep } = recordingSleep();
  expect(() =>
    withRateLimitRecoverySync(
      () => {
        throw secondaryLimitError();
      },
      { probe: () => undefined, sleep },
    ),
  ).toThrow("Command failed");
  expect(delays).toEqual([]);
});
