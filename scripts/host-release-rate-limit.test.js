import { expect, test } from "bun:test";
import {
  rateLimitRecoveries,
  rateLimitRetries,
  secondaryRateLimitWaitMs,
} from "./github-retry.mjs";
import { assetNames, fixture } from "./host-release-test-fixture.mjs";
import {
  preflightHostReleaseWithRecovery,
  publishHostReleaseWithRecovery,
} from "./publish-host-release.mjs";

const rateLimitError = () =>
  Object.assign(new Error("Command failed: gh api"), {
    stderr:
      "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID SYNTHETIC (HTTP 403)\n",
  });

const isRemote = (command, args) =>
  (command === "gh" && args[0] === "api" && args[1] !== "rate_limit") ||
  (command === "pukbot" && !args.includes("--dry-run"));

function limitedGitHub(value, { exhaustAt = [], landsBeforeFailure = false }) {
  let remoteCalls = 0;
  let exhausted = false;
  const pending = new Set(exhaustAt);
  const waits = [];
  const probes = [];
  const execute = (command, args, options) => {
    if (command === "gh" && args[0] === "api" && args[1] === "rate_limit") {
      probes.push(exhausted);
      const reset = Math.ceil(Date.now() / 1000) + 60;
      return exhausted ? `0 ${reset}\n` : `4990 ${reset}\n`;
    }
    if (!isRemote(command, args)) return value.execute(command, args, options);
    remoteCalls++;
    if (pending.delete(remoteCalls)) {
      exhausted = true;
      if (landsBeforeFailure && command === "pukbot")
        value.execute(command, args, options);
    }
    if (exhausted) throw rateLimitError();
    return value.execute(command, args, options);
  };
  return {
    execute,
    waits,
    probes,
    get remoteCalls() {
      return remoteCalls;
    },
    rateLimit: {
      sleep: async (milliseconds) => {
        waits.push(milliseconds);
        exhausted = false;
      },
    },
  };
}

function publishLimited(value, github) {
  return publishHostReleaseWithRecovery({
    directory: value.directory,
    repository: "synthetic/fixture",
    tag: "v1.2.3",
    target: "a".repeat(40),
    execute: github.execute,
    matchesAsset: value.matchesAsset,
    rateLimit: github.rateLimit,
    retry: github.rateLimit,
  });
}

function expectSinglePublishedRelease(value) {
  expect(value.release.draft).toBe(false);
  expect(value.release.id).toBe(7);
  expect(value.release.assets.map((asset) => asset.name).sort()).toEqual(
    [...assetNames].sort(),
  );
  const landed = value.calls.filter(
    (args) => args[0] === "pukbot" && !args.includes("--dry-run"),
  );
  expect(landed.filter((args) => args[2] === "create")).toHaveLength(1);
  expect(landed.filter((args) => args[2] === "upload-asset")).toHaveLength(
    assetNames.length,
  );
}

async function cleanRemoteCallCount() {
  const value = fixture();
  try {
    const github = limitedGitHub(value, {});
    await publishLimited(value, github);
    return github.remoteCalls;
  } finally {
    value.clean();
  }
}

test("an exhausted rate limit in the middle of the asset uploads waits for the reset and resumes the same draft", async () => {
  const value = fixture();
  try {
    let uploads = 0;
    let exhausted = false;
    const waits = [];
    const sleep = async (milliseconds) => {
      waits.push(milliseconds);
      exhausted = false;
    };
    const execute = (command, args, options) => {
      if (command === "gh" && args[1] === "rate_limit")
        return exhausted
          ? `0 ${Math.ceil(Date.now() / 1000) + 60}`
          : `4990 ${Math.ceil(Date.now() / 1000) + 3600}`;
      if (
        command === "pukbot" &&
        args[1] === "upload-asset" &&
        !args.includes("--dry-run") &&
        ++uploads === 3
      )
        exhausted = true;
      if (exhausted && isRemote(command, args)) throw rateLimitError();
      return value.execute(command, args, options);
    };
    const result = await publishHostReleaseWithRecovery({
      directory: value.directory,
      repository: "synthetic/fixture",
      tag: "v1.2.3",
      target: "a".repeat(40),
      execute,
      matchesAsset: value.matchesAsset,
      rateLimit: { sleep },
      retry: { sleep },
    });
    expect(result.assets).toEqual(assetNames);
    expect(waits).toHaveLength(1);
    expect(waits[0]).toBeGreaterThan(60_000);
    expect(waits[0]).toBeLessThanOrEqual(66_000);
    expectSinglePublishedRelease(value);
  } finally {
    value.clean();
  }
});

const cleanTotal = await cleanRemoteCallCount();

test("a clean publication makes enough remote calls to exercise recovery", () => {
  expect(cleanTotal).toBeGreaterThan(20);
});

for (const landsBeforeFailure of [false, true])
  for (let call = 1; call <= cleanTotal; call++)
    test(`publication recovers when the rate limit runs out at remote call ${call} of ${cleanTotal} (write landed: ${landsBeforeFailure})`, async () => {
      const value = fixture();
      try {
        const github = limitedGitHub(value, {
          exhaustAt: [call],
          landsBeforeFailure,
        });
        await publishLimited(value, github);
        expect(github.waits).toHaveLength(1);
        expectSinglePublishedRelease(value);
      } finally {
        value.clean();
      }
    }, 30_000);

test("publication survives two consecutive exhausted windows", async () => {
  const value = fixture();
  try {
    const github = limitedGitHub(value, { exhaustAt: [4, 12] });
    await publishLimited(value, github);
    expect(github.waits).toHaveLength(2);
    expectSinglePublishedRelease(value);
  } finally {
    value.clean();
  }
});

test("publication survives a third exhausted window without restarting", async () => {
  const value = fixture();
  try {
    const github = limitedGitHub(value, { exhaustAt: [4, 12, 20] });
    await publishLimited(value, github);
    expect(github.waits).toHaveLength(3);
    expectSinglePublishedRelease(value);
  } finally {
    value.clean();
  }
});

test("a rate limit that never clears stops after bounded waits and leaves an unpublished draft", async () => {
  const value = fixture();
  try {
    const github = limitedGitHub(value, { exhaustAt: [4] });
    const waits = [];
    const sleep = async (milliseconds) => {
      waits.push(milliseconds);
    };
    await expect(
      publishHostReleaseWithRecovery({
        directory: value.directory,
        repository: "synthetic/fixture",
        tag: "v1.2.3",
        target: "a".repeat(40),
        execute: github.execute,
        matchesAsset: value.matchesAsset,
        rateLimit: { sleep },
        retry: { sleep },
      }),
    ).rejects.toThrow("Command failed");
    expect(waits).toHaveLength(
      (rateLimitRetries + 1) * (rateLimitRecoveries + 1) - 1,
    );
    expect(value.release?.draft ?? true).toBe(true);
  } finally {
    value.clean();
  }
});

test("failures with rate limit left are not retried and never wait", async () => {
  const value = fixture();
  try {
    const waits = [];
    const probes = [];
    await expect(
      publishHostReleaseWithRecovery({
        directory: value.directory,
        repository: "synthetic/fixture",
        tag: "v1.2.3",
        target: "a".repeat(40),
        execute: (command, args, options) => {
          if (command === "gh" && args[1] === "rate_limit") {
            probes.push(args);
            return `4990 ${Math.ceil(Date.now() / 1000) + 3600}`;
          }
          if (
            command === "pukbot" &&
            args[1] === "upload-asset" &&
            !args.includes("--dry-run")
          )
            throw Object.assign(new Error("Command failed: pukbot"), {
              stderr: "HTTP 403: Resource not accessible by integration",
            });
          return value.execute(command, args, options);
        },
        matchesAsset: value.matchesAsset,
        rateLimit: { sleep: async (milliseconds) => waits.push(milliseconds) },
      }),
    ).rejects.toThrow();
    expect(probes).toHaveLength(1);
    expect(waits).toEqual([]);
    expect(value.release.draft).toBe(true);
  } finally {
    value.clean();
  }
});

test("an unreadable rate limit probe waits a bounded secondary backoff, then fails with the original error", async () => {
  const value = fixture();
  try {
    const waits = [];
    const sleep = async (milliseconds) => waits.push(milliseconds);
    await expect(
      publishHostReleaseWithRecovery({
        directory: value.directory,
        repository: "synthetic/fixture",
        tag: "v1.2.3",
        target: "a".repeat(40),
        execute: (command, args, options) => {
          if (command === "gh" && args[1] === "rate_limit")
            throw rateLimitError();
          if (isRemote(command, args)) throw rateLimitError();
          return value.execute(command, args, options);
        },
        matchesAsset: value.matchesAsset,
        rateLimit: { sleep },
        retry: { sleep, random: () => 0 },
      }),
    ).rejects.toThrow("Command failed: gh api");
    expect(waits).toEqual([
      secondaryRateLimitWaitMs,
      2 * secondaryRateLimitWaitMs,
      4 * secondaryRateLimitWaitMs,
    ]);
  } finally {
    value.clean();
  }
});

test("preflight waits out an exhausted rate limit before accepting the assets", () => {
  const value = fixture();
  try {
    let exhausted = true;
    const waits = [];
    const sleep = (milliseconds) => {
      waits.push(milliseconds);
      exhausted = false;
    };
    const assets = preflightHostReleaseWithRecovery({
      directory: value.directory,
      repository: "synthetic/fixture",
      tag: "v1.2.3",
      source: "a".repeat(40),
      execute: (command, args, options) => {
        if (command === "gh" && args[1] === "rate_limit")
          return `${exhausted ? 0 : 4990} ${Math.ceil(Date.now() / 1000) + 30}`;
        if (exhausted && command === "pukbot") throw rateLimitError();
        return value.execute(command, args, options);
      },
      rateLimit: { sleep },
      retry: { sleep },
    });
    expect(assets).toEqual(assetNames);
    expect(waits).toHaveLength(1);
    expect(value.calls.some((args) => args[0] === "pukbot")).toBe(true);
  } finally {
    value.clean();
  }
});
