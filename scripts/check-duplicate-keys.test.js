import { expect, test } from "bun:test";
import { findLiterals, scanFiles } from "./check-duplicate-keys.mjs";

test("finds forKey literals with their line numbers", () => {
  const text = [
    'let a = d.bool(forKey: "presenterAutoActive")',
    "",
    'd.set(true, forKey: "presenterAutoActive")',
  ].join("\n");
  expect(findLiterals(text)).toEqual([
    { literal: "presenterAutoActive", line: 1 },
    { literal: "presenterAutoActive", line: 3 },
  ]);
});

test("short literals are ignored", () => {
  expect(findLiterals('d.bool(forKey: "ab")')).toEqual([]);
});

test("a literal used in only one file is not a finding", () => {
  const findings = scanFiles([
    {
      path: "Sources/A.swift",
      text: 'd.bool(forKey: "onlyHere")\nd.set(true, forKey: "onlyHere")',
    },
  ]);
  expect(findings).toEqual([]);
});

test("a literal repeated across two files is a finding", () => {
  const findings = scanFiles([
    { path: "Sources/A.swift", text: 'd.bool(forKey: "sharedKey")' },
    { path: "Sources/B.swift", text: 'd.set(true, forKey: "sharedKey")' },
  ]);
  expect(findings).toEqual([
    {
      literal: "sharedKey",
      sites: [
        { path: "Sources/A.swift", line: 1 },
        { path: "Sources/B.swift", line: 1 },
      ],
    },
  ]);
});

test("the same literal repeated twice in one file is not a finding", () => {
  const findings = scanFiles([
    {
      path: "Sources/A.swift",
      text: 'd.bool(forKey: "sameFile")\nd.set(true, forKey: "sameFile")',
    },
  ]);
  expect(findings).toEqual([]);
});

test("findings are sorted by literal", () => {
  const findings = scanFiles([
    {
      path: "Sources/A.swift",
      text: 'd.bool(forKey: "zKey")\nd.bool(forKey: "aKey")',
    },
    {
      path: "Sources/B.swift",
      text: 'd.bool(forKey: "zKey")\nd.bool(forKey: "aKey")',
    },
  ]);
  expect(findings.map((f) => f.literal)).toEqual(["aKey", "zKey"]);
});
