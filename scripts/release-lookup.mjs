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

export function lookupRelease({
  repository,
  tag,
  execute = execFileSync,
  maximumPages = 20,
  retry = {},
}) {
  if (
    !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repository) ||
    repository.split("/").some((part) => part === "." || part === "..") ||
    typeof tag !== "string" ||
    tag.length < 1 ||
    tag.length > 200 ||
    /\s/.test(tag) ||
    [...tag].some(
      (character) =>
        character.charCodeAt(0) < 32 || character.charCodeAt(0) === 127,
    ) ||
    !Number.isSafeInteger(maximumPages) ||
    maximumPages < 1 ||
    maximumPages > 20
  )
    throw new Error("Invalid release lookup identity");
  const read = (path) =>
    withGitHubRetrySync(
      () =>
        JSON.parse(
          execute("gh", ["api", path], {
            encoding: "utf8",
            timeout: 60_000,
            maxBuffer: 4 * 1024 ** 2,
          }),
        ),
      retry,
    );
  try {
    return validateRelease(
      read(`repos/${repository}/releases/tags/${encodeURIComponent(tag)}`),
      tag,
    );
  } catch (error) {
    if (!/\bHTTP 404\b/.test(String(error.stderr))) throw error;
  }
  const seen = new Set();
  const matches = [];
  for (let page = 1; page <= maximumPages; page++) {
    const values = read(
      `repos/${repository}/releases?per_page=100&page=${page}`,
    );
    if (!Array.isArray(values) || values.length > 100)
      throw new Error("Invalid release lookup page");
    for (const value of values) {
      validateRelease(value);
      if (seen.has(value.id)) throw new Error("Duplicate release lookup ID");
      seen.add(value.id);
      if (value.tag_name === tag) matches.push(value);
    }
    if (matches.length > 1) throw new Error("Ambiguous release lookup tag");
    if (values.length < 100) return matches[0];
  }
  throw new Error("Release lookup pagination limit exceeded");
}
