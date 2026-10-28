import { execFileSync } from "node:child_process";
import { withGitHubRetrySync } from "./github-retry.mjs";

function validateRelease(value, tag) {
  if (
    !value ||
    typeof value !== "object" ||
    Array.isArray(value) ||
    !Number.isSafeInteger(value.id) ||
    value.id < 1 ||
    typeof value.tag_name !== "string" ||
    value.tag_name.length < 1 ||
    typeof value.draft !== "boolean" ||
    !Array.isArray(value.assets) ||
    (tag !== undefined && value.tag_name !== tag)
  )
    throw new Error("Invalid release lookup response");
  return value;
}

export function isMissingLookup(error) {
  return /\bHTTP 404\b/.test(String(error?.stderr));
}

export function readGitHubAPI({
  path,
  execute = execFileSync,
  retry = {},
  allowMissing = false,
  maxBuffer = 4 * 1024 ** 2,
}) {
  try {
    return withGitHubRetrySync(
      () =>
        JSON.parse(
          execute("gh", ["api", path], {
            encoding: "utf8",
            timeout: 60_000,
            killSignal: "SIGKILL",
            maxBuffer,
            stdio: ["ignore", "pipe", "pipe"],
          }),
        ),
      retry,
    );
  } catch (error) {
    if (allowMissing && isMissingLookup(error)) return undefined;
    throw error;
  }
}

function validateIdentity({ repository, tag, releaseID, maximumPages }) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    repository.split("/").some((part) => part === "." || part === "..") ||
    (tag !== undefined &&
      (typeof tag !== "string" ||
        tag.length < 1 ||
        tag.length > 200 ||
        /\s/.test(tag) ||
        [...tag].some(
          (character) =>
            character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127,
        ))) ||
    (releaseID !== undefined &&
      (!Number.isSafeInteger(releaseID) || releaseID < 1)) ||
    !Number.isSafeInteger(maximumPages) ||
    maximumPages < 1 ||
    maximumPages > 20
  )
    throw new Error("Invalid release lookup identity");
}

export function listReleases({
  repository,
  execute = execFileSync,
  maximumPages = 20,
  retry = {},
}) {
  validateIdentity({ repository, maximumPages });
  const seen = new Set();
  const releases = [];
  for (let page = 1; page <= maximumPages; page++) {
    const values = readGitHubAPI({
      path: `repos/${repository}/releases?per_page=100&page=${page}`,
      execute,
      retry,
    });
    if (!Array.isArray(values) || values.length > 100)
      throw new Error("Invalid release lookup page");
    const pageIDs = new Set();
    for (const value of values) {
      validateRelease(value);
      if (pageIDs.has(value.id)) throw new Error("Duplicate release lookup ID");
      pageIDs.add(value.id);
      if (seen.has(value.id)) continue;
      seen.add(value.id);
      releases.push(value);
    }
    if (values.length < 100) return releases;
  }
  throw new Error("Release lookup pagination limit exceeded");
}

export function releaseFromListing(releases, tag) {
  const matches = releases.filter((value) => value.tag_name === tag);
  if (matches.length > 1) throw new Error("Ambiguous release lookup tag");
  return matches[0];
}

export function lookupRelease({
  repository,
  tag,
  releaseID,
  execute = execFileSync,
  maximumPages = 20,
  retry = {},
}) {
  if (typeof tag !== "string")
    throw new Error("Invalid release lookup identity");
  validateIdentity({ repository, tag, releaseID, maximumPages });
  const read = (path) =>
    readGitHubAPI({ path, execute, retry, allowMissing: true });
  if (releaseID !== undefined) {
    const value = read(`repos/${repository}/releases/${releaseID}`);
    if (value === undefined) return undefined;
    validateRelease(value, tag);
    if (value.id !== releaseID) throw new Error("Invalid release lookup ID");
    return value;
  }
  const tagged = read(
    `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`,
  );
  if (tagged !== undefined) return validateRelease(tagged, tag);
  return releaseFromListing(
    listReleases({ repository, execute, maximumPages, retry }),
    tag,
  );
}
