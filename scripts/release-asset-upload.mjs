import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";
import { TransientGitHubError, withGitHubRetrySync } from "./github-retry.mjs";
import { lookupRelease, readGitHubAPI } from "./release-lookup.mjs";

function assetArguments({ repository, releaseID, file, name }) {
  const size = statSync(file).size;
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    !Number.isSafeInteger(releaseID) ||
    releaseID <= 0 ||
    !/^[A-Za-z0-9_.-]+$/.test(name) ||
    !Number.isSafeInteger(size) ||
    size <= 0 ||
    size > 1024 ** 3
  )
    throw new Error("Invalid release asset");
  return [
    "release",
    "upload-asset",
    String(releaseID),
    file,
    "--repo",
    repository,
    "--name",
    name,
  ];
}

function runAssetRequest(args, execute, timeout = 120_000) {
  const result = JSON.parse(
    execute("pukbot", [...args, "--json"], {
      encoding: "utf8",
      timeout,
      killSignal: "SIGKILL",
      maxBuffer: 2 * 1024 ** 2,
    }),
  );
  if (result.ok === false)
    throw new Error(result.error?.message ?? "Release asset request failed");
  return result;
}

function watchWorkflow(workflowUrl, execute, timeout) {
  const match =
    /^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/actions\/runs\/([1-9][0-9]*)$/.exec(
      workflowUrl,
    );
  if (!match) throw new Error("Invalid release mutation workflow identity");
  try {
    execute(
      "gh",
      [
        "run",
        "watch",
        match[3],
        "--repo",
        `${match[1]}/${match[2]}`,
        "--exit-status",
      ],
      {
        encoding: "utf8",
        timeout,
        killSignal: "SIGKILL",
        maxBuffer: 2 * 1024 ** 2,
      },
    );
  } catch (error) {
    if (error?.code === "ETIMEDOUT" || error?.signal) throw error;
    throw new TransientGitHubError(
      `Pukbot workflow failed: ${workflowUrl}: ${error?.message}`,
      {
        cause: error,
      },
    );
  }
}

const booleanMutationFlags = new Set([
  "--draft",
  "--prerelease",
  "--generate-notes",
  "--dry-run",
]);

function mutationArguments(args) {
  const positional = [];
  const flags = {};
  for (let index = 2; index < args.length; index++) {
    const argument = args[index];
    if (!argument.startsWith("--")) positional.push(argument);
    else if (
      booleanMutationFlags.has(argument) ||
      index + 1 >= args.length ||
      args[index + 1].startsWith("--")
    )
      flags[argument] = true;
    else flags[argument] = args[++index];
  }
  return { positional, flags };
}

function readTagCommit({ repository, tag, execute, retry }) {
  return readGitHubAPI({
    path: `repos/${repository}/git/ref/tags/${encodeURIComponent(tag)}`,
    execute,
    retry,
    allowMissing: true,
    maxBuffer: 1024 ** 2,
  });
}

export function createdObjectConfirmation(args, execute, retry = {}) {
  if (args[1] !== "create" || args.includes("--dry-run")) return undefined;
  const { positional, flags } = mutationArguments(args);
  const repository = flags["--repo"];
  const target = flags["--target"];
  const [tag] = positional;
  if (
    positional.length !== 1 ||
    typeof repository !== "string" ||
    typeof target !== "string"
  )
    return undefined;
  if (args[0] === "release")
    return () => {
      const release = lookupRelease({ repository, tag, execute, retry });
      return Boolean(
        release &&
          release.tag_name === tag &&
          release.target_commitish === target &&
          release.draft === Boolean(flags["--draft"]) &&
          release.prerelease === Boolean(flags["--prerelease"]),
      );
    };
  if (args[0] === "tag")
    return () => {
      const reference = readTagCommit({ repository, tag, execute, retry });
      return Boolean(
        reference &&
          reference.ref === `refs/tags/${tag}` &&
          reference.object?.type === "commit" &&
          reference.object.sha === target,
      );
    };
  return undefined;
}

function retryMutation(operation, { confirm, confirmed, remaining, retry }) {
  return withGitHubRetrySync(
    (attempt) => {
      try {
        return operation();
      } catch (error) {
        if (attempt > 1 && confirm?.()) return confirmed;
        throw error;
      }
    },
    {
      ...retry,
      remaining,
      beforeRetry:
        confirm && (() => (confirm() ? { value: confirmed } : undefined)),
    },
  );
}

function isAssetCapacityError(error, file) {
  let structuredMessage;
  try {
    const result = JSON.parse(error?.stdout?.toString() ?? "");
    if (
      result?.ok === false &&
      result.error?.code === "command_failed" &&
      result.error?.message ===
        "release asset must be between 1 and 40000 bytes"
    )
      structuredMessage = result.error.message;
  } catch {}
  const messages = [
    error?.message,
    error?.stderr?.toString(),
    structuredMessage,
  ];
  return (
    statSync(file).size > 40_000 &&
    messages.some((message) =>
      /release asset must be between 1 and 40000 bytes/.test(message ?? ""),
    )
  );
}

export function preflightReleaseAsset({
  repository,
  file,
  name = basename(file),
  execute = execFileSync,
  retry = {},
}) {
  const args = assetArguments({ repository, releaseID: 1, file, name });
  try {
    withGitHubRetrySync(
      () => runAssetRequest([...args, "--dry-run"], execute),
      retry,
    );
    return "pukbot";
  } catch (error) {
    if (!isAssetCapacityError(error, file)) throw error;
    execute("gh", ["release", "upload", "--help"], {
      encoding: "utf8",
      timeout: 15_000,
    });
    return "gh";
  }
}

function releaseRequestDeadline({ totalTimeoutMs, now, operation }) {
  if (
    !Number.isSafeInteger(totalTimeoutMs) ||
    totalTimeoutMs < 1 ||
    totalTimeoutMs > 30 * 60_000
  )
    throw new Error(`Invalid release ${operation} deadline`);
  const started = now();
  if (!Number.isFinite(started))
    throw new Error(`Invalid release ${operation} clock`);
  const deadline = started + totalTimeoutMs;
  const remaining = () => {
    const current = now();
    if (!Number.isFinite(current) || current < started)
      throw new Error(`Invalid release ${operation} clock`);
    const duration = Math.floor(deadline - current);
    if (duration < 1)
      throw new Error(`Release ${operation} total deadline exceeded`);
    return duration;
  };
  return remaining;
}

export function executeReleaseMutation(
  args,
  {
    execute = execFileSync,
    totalTimeoutMs = 30 * 60_000,
    now = () => performance.now(),
    retry = {},
  } = {},
) {
  const remaining = releaseRequestDeadline({
    totalTimeoutMs,
    now,
    operation: "mutation",
  });
  const result = retryMutation(
    () => {
      const result = runAssetRequest(args, execute, remaining());
      if (result.workflowUrl)
        watchWorkflow(result.workflowUrl, execute, remaining());
      return result;
    },
    {
      confirm: createdObjectConfirmation(args, execute, retry),
      confirmed: { ok: true, confirmed: true },
      remaining,
      retry,
    },
  );
  remaining();
  return result;
}

export async function uploadReleaseAsset({
  repository,
  releaseID,
  tag,
  file,
  name = basename(file),
  execute = execFileSync,
  totalTimeoutMs = 30 * 60_000,
  now = () => performance.now(),
  retry = {},
}) {
  const remaining = releaseRequestDeadline({
    totalTimeoutMs,
    now,
    operation: "asset upload",
  });
  const args = assetArguments({ repository, releaseID, file, name });
  const size = statSync(file).size;
  const confirm =
    typeof tag === "string"
      ? () => {
          const release = lookupRelease({
            repository,
            tag,
            releaseID,
            execute,
            retry,
          });
          return Boolean(
            release?.id === releaseID &&
              release.assets.some(
                (asset) =>
                  asset.name === name &&
                  asset.size === size &&
                  asset.state === "uploaded",
              ),
          );
        }
      : undefined;
  try {
    const result = retryMutation(
      () => {
        const result = runAssetRequest(args, execute, remaining());
        if (result.workflowUrl)
          watchWorkflow(result.workflowUrl, execute, remaining());
        return "pukbot";
      },
      { confirm, confirmed: "pukbot", remaining, retry },
    );
    remaining();
    return result;
  } catch (error) {
    if (!isAssetCapacityError(error, file)) throw error;
    if (!Number.isSafeInteger(releaseID) || releaseID < 1)
      throw new Error("Invalid release ID");
    const temporary = await mkdtemp(join(tmpdir(), "edith-release-upload-"));
    try {
      const upload = join(temporary, name);
      await copyFile(file, upload);
      retryMutation(
        () =>
          execute(
            "gh",
            [
              "api",
              "--method",
              "POST",
              "-H",
              "Content-Type: application/octet-stream",
              `https://uploads.github.com/repos/${repository}/releases/${releaseID}/assets?name=${encodeURIComponent(name)}`,
              "--input",
              upload,
            ],
            {
              encoding: "utf8",
              timeout: remaining(),
              killSignal: "SIGKILL",
            },
          ),
        { confirm, confirmed: "gh", remaining, retry },
      );
      remaining();
      return "gh";
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }
}
