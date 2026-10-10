import { execFileSync } from "node:child_process";
import { statSync } from "node:fs";
import { copyFile, mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, join } from "node:path";

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

function runAssetRequest(args, execute) {
  const result = JSON.parse(
    execute("pukbot", [...args, "--json"], {
      encoding: "utf8",
      timeout: 120_000,
      maxBuffer: 2 * 1024 ** 2,
    }),
  );
  if (result.ok === false)
    throw new Error(result.error?.message ?? "Release asset request failed");
  return result;
}

function isAssetCapacityError(error, file) {
  const messages = [error?.message, error?.stderr?.toString()];
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
}) {
  const args = assetArguments({ repository, releaseID: 1, file, name });
  try {
    runAssetRequest([...args, "--dry-run"], execute);
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

export async function uploadReleaseAsset({
  repository,
  releaseID,
  tag,
  file,
  name = basename(file),
  execute = execFileSync,
}) {
  const args = assetArguments({ repository, releaseID, file, name });
  try {
    const result = runAssetRequest(args, execute);
    if (result.workflowUrl) {
      const url = new URL(result.workflowUrl);
      const parts = url.pathname.split("/").filter(Boolean);
      execute(
        "gh",
        [
          "run",
          "watch",
          parts.at(-1),
          "--repo",
          `${parts[0]}/${parts[1]}`,
          "--exit-status",
        ],
        {
          encoding: "utf8",
          timeout: 120_000,
        },
      );
    }
    return "pukbot";
  } catch (error) {
    if (!isAssetCapacityError(error, file)) throw error;
    if (typeof tag !== "string" || !/^[A-Za-z0-9][A-Za-z0-9/_.-]*$/.test(tag))
      throw new Error("Invalid release tag");
    const temporary = await mkdtemp(join(tmpdir(), "edith-release-upload-"));
    try {
      const upload = join(temporary, name);
      await copyFile(file, upload);
      execute("gh", ["release", "upload", tag, upload, "--repo", repository], {
        encoding: "utf8",
        timeout: 120_000,
      });
      return "gh";
    } finally {
      await rm(temporary, { recursive: true, force: true });
    }
  }
}
