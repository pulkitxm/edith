import { expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  listReleases,
  lookupRelease,
  readGitHubAPI,
  releaseFromListing,
} from "./release-lookup.mjs";

const repository = "synthetic/fixture";
const tag = "extensions/calendar/1.0.0-source";
const item = { id: 7, tag_name: tag, draft: true, assets: [] };
const missing = () => {
  throw Object.assign(new Error("Not found"), {
    stderr: Buffer.from("gh: Not Found (HTTP 404)"),
  });
};

function lookup(pages, overrides = {}) {
  const calls = [];
  const value = lookupRelease({
    repository,
    tag,
    execute: (_command, args) => {
      calls.push(args[1]);
      if (args[1].includes("/tags/")) return missing();
      return JSON.stringify(pages[Number(args[1].split("page=").at(-1)) - 1]);
    },
    ...overrides,
  });
  return { value, calls };
}

test("first absence and an untagged created draft use exact-tag authenticated listing", () => {
  expect(lookup([[]]).value).toBeUndefined();
  const result = lookup([[item]]);
  expect(result.value).toEqual(item);
  expect(result.calls).toEqual([
    `repos/${repository}/releases/tags/${encodeURIComponent(tag)}`,
    `repos/${repository}/releases?per_page=100&page=1`,
  ]);
});

test("a resumed draft can be on a later page without choosing a foreign release", () => {
  const first = Array.from({ length: 100 }, (_, index) => ({
    ...item,
    id: index + 100,
    tag_name: `foreign-${index}`,
  }));
  const result = lookup([first, [item]]);
  expect(result.value).toEqual(item);
  expect(result.calls).toHaveLength(3);
});

test("published lookup does not scan unrelated releases", () => {
  const calls = [];
  expect(
    lookupRelease({
      repository,
      tag,
      execute: (_command, args) => {
        calls.push(args);
        return JSON.stringify({ ...item, draft: false });
      },
    }).draft,
  ).toBe(false);
  expect(calls).toHaveLength(1);
});

test("authentication and server errors never become bootstrap absence", () => {
  for (const [status, attempts] of [
    [403, 1],
    [429, 6],
    [500, 6],
  ]) {
    let calls = 0;
    expect(() =>
      lookupRelease({
        repository,
        tag,
        retry: { sleep: () => {} },
        execute: () => {
          calls++;
          throw Object.assign(new Error("Denied"), {
            stderr: `gh: Denied (HTTP ${status})`,
          });
        },
      }),
    ).toThrow("Denied");
    expect(calls).toBe(attempts);
  }
});

test("malformed and foreign tagged responses do not fall back to a listing", () => {
  for (const [body, attempts] of [
    ["broken", 6],
    ["", 6],
    ["null", 1],
    ["[]", 1],
    [JSON.stringify({ ...item, tag_name: "foreign" }), 1],
  ]) {
    let calls = 0;
    expect(() =>
      lookupRelease({
        repository,
        tag,
        retry: { sleep: () => {} },
        execute: () => {
          calls++;
          return body;
        },
      }),
    ).toThrow();
    expect(calls).toBe(attempts);
  }
});

test("malformed pages, duplicate IDs and ambiguous exact tags fail closed", () => {
  for (const page of [
    {},
    [null],
    [{ ...item, id: "7" }],
    [{ ...item, draft: "true" }],
    [{ ...item, assets: null }],
    [item, item],
    [item, { ...item, id: 8 }],
  ])
    expect(() => lookup([page])).toThrow();
});

test("pagination is bounded and repeated IDs across pages reject", () => {
  const page = Array.from({ length: 100 }, (_, index) => ({
    ...item,
    id: index + 100,
    tag_name: `foreign-${index}`,
  }));
  expect(() => lookup([page, [{ ...item, id: 100 }]])).toThrow("Duplicate");
  expect(() => lookup([page], { maximumPages: 1 })).toThrow("pagination limit");
});

test("a release created between page reads restarts the listing instead of failing", () => {
  const page = Array.from({ length: 100 }, (_, index) => ({
    ...item,
    id: index + 100,
    tag_name: `foreign-${index}`,
  }));
  const shifted = [[page, [page[99], item]], [page, [item]]];
  const calls = [];
  let listing = 0;
  const releases = listReleases({
    repository,
    execute: (_command, args) => {
      calls.push(args[1]);
      const pageNumber = Number(args[1].split("page=").at(-1));
      if (pageNumber === 1 && calls.length > 1) listing++;
      return JSON.stringify(shifted[listing][pageNumber - 1]);
    },
  });
  expect(releases.map(({ id }) => id)).toEqual([...page.map(({ id }) => id), 7]);
  expect(calls).toHaveLength(4);
});

test("invalid identities reject before any process starts", () => {
  for (const value of [
    { repository: "../foreign" },
    { tag: "bad\nvalue" },
    { maximumPages: 21 },
  ]) {
    let calls = 0;
    expect(() =>
      lookupRelease({
        repository,
        tag,
        execute: () => {
          calls++;
        },
        ...value,
      }),
    ).toThrow();
    expect(calls).toBe(0);
  }
});

test("a known release ID is one direct read with no tag probe or listing", () => {
  const calls = [];
  const value = lookupRelease({
    repository,
    tag,
    releaseID: 7,
    execute: (_command, args, options) => {
      calls.push([args[1], options.stdio]);
      return JSON.stringify(item);
    },
  });
  expect(value).toEqual(item);
  expect(calls).toEqual([
    [`repos/${repository}/releases/7`, ["ignore", "pipe", "pipe"]],
  ]);
  expect(() =>
    lookupRelease({
      repository,
      tag,
      releaseID: 7,
      execute: () => JSON.stringify({ ...item, id: 8 }),
    }),
  ).toThrow("Invalid release lookup ID");
  expect(() =>
    lookupRelease({
      repository,
      tag,
      releaseID: 7,
      execute: () => JSON.stringify({ ...item, tag_name: "foreign" }),
    }),
  ).toThrow("Invalid release lookup response");
  expect(
    lookupRelease({ repository, tag, releaseID: 7, execute: missing }),
  ).toBeUndefined();
  expect(() =>
    lookupRelease({ repository, tag, releaseID: 0, execute: missing }),
  ).toThrow("Invalid release lookup identity");
});

test("one release listing answers every tag without per-tag probes", () => {
  const calls = [];
  const releases = Array.from({ length: 40 }, (_, index) => ({
    ...item,
    id: index + 1,
    tag_name: `extensions/package${index}/1.0.0-source`,
  }));
  const listed = listReleases({
    repository,
    execute: (_command, args) => {
      calls.push(args[1]);
      return JSON.stringify(releases);
    },
  });
  for (const [index, value] of releases.entries())
    expect(
      releaseFromListing(listed, `extensions/package${index}/1.0.0-source`),
    ).toEqual(value);
  expect(releaseFromListing(listed, "extensions/absent/1.0.0")).toBeUndefined();
  expect(calls).toEqual([`repos/${repository}/releases?per_page=100&page=1`]);
  expect(() => releaseFromListing([item, { ...item, id: 8 }], tag)).toThrow(
    "Ambiguous",
  );
});

function fakeGitHubCLI(status) {
  const directory = mkdtempSync(join(tmpdir(), "release-lookup-gh-"));
  writeFileSync(
    join(directory, "gh"),
    `#!/bin/sh\nprintf '{"message":"synthetic"}'\nprintf 'gh: Synthetic (HTTP ${status})\\n' >&2\nexit 1\n`,
    { mode: 0o700 },
  );
  const script = join(directory, "lookup.mjs");
  writeFileSync(
    script,
    `import { lookupRelease, readGitHubAPI } from ${JSON.stringify(resolve("scripts/release-lookup.mjs"))};
const missingByID = lookupRelease({ repository: "synthetic/fixture", tag: "synthetic-tag", releaseID: 7, retry: { sleep: () => {} } });
const missingRef = readGitHubAPI({ path: "repos/synthetic/fixture/git/ref/tags/synthetic-tag", allowMissing: true, retry: { sleep: () => {} } });
process.stdout.write(JSON.stringify([missingByID ?? null, missingRef ?? null]));
`,
  );
  const result = spawnSync(process.execPath, [script], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${directory}:${process.env.PATH}` },
  });
  rmSync(directory, { recursive: true, force: true });
  return result;
}

test("expected 404 lookups print nothing and return missing", () => {
  const result = fakeGitHubCLI(404);
  expect(result.status).toBe(0);
  expect(result.stdout).toBe("[null,null]");
  expect(result.stderr).toBe("");
});

test("non-404 lookup failures still throw with the gh message", () => {
  const result = fakeGitHubCLI(403);
  expect(result.status).not.toBe(0);
  expect(result.stderr).toContain("HTTP 403");
  for (const status of [403, 422]) {
    let calls = 0;
    expect(() =>
      readGitHubAPI({
        path: "repos/synthetic/fixture/releases/7",
        allowMissing: true,
        retry: { sleep: () => {} },
        execute: () => {
          calls++;
          throw Object.assign(
            new Error(`Command failed: gh: Denied (HTTP ${status})`),
            {
              stderr: `gh: Denied (HTTP ${status})`,
            },
          );
        },
      }),
    ).toThrow(`HTTP ${status}`);
    expect(calls).toBe(1);
  }
  let calls = 0;
  expect(() =>
    readGitHubAPI({
      path: "repos/synthetic/fixture/releases/7",
      allowMissing: true,
      retry: { sleep: () => {} },
      execute: () => {
        calls++;
        throw Object.assign(new Error("Command failed"), {
          stderr: "gh: Server Error (HTTP 502)",
        });
      },
    }),
  ).toThrow();
  expect(calls).toBe(6);
});
