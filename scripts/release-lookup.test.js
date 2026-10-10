import { expect, test } from "bun:test";
import { lookupRelease } from "./release-lookup.mjs";

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
  for (const status of [403, 429, 500]) {
    let calls = 0;
    expect(() =>
      lookupRelease({
        repository,
        tag,
        execute: () => {
          calls++;
          throw Object.assign(new Error("Denied"), {
            stderr: `gh: Denied (HTTP ${status})`,
          });
        },
      }),
    ).toThrow("Denied");
    expect(calls).toBe(1);
  }
});

test("malformed and foreign tagged responses do not fall back to a listing", () => {
  for (const body of [
    "broken",
    "null",
    "[]",
    JSON.stringify({ ...item, tag_name: "foreign" }),
  ]) {
    let calls = 0;
    expect(() =>
      lookupRelease({
        repository,
        tag,
        execute: () => {
          calls++;
          return body;
        },
      }),
    ).toThrow();
    expect(calls).toBe(1);
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
