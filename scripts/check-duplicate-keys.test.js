import { expect, test } from "bun:test";
import {
  findLiterals,
  isShippingSource,
  scanFiles,
} from "./check-duplicate-keys.mjs";

test("checks independent shipping modules without unbuilt monolithic source copies", () => {
  for (const path of [
    "Packages/EdithHost/Sources/EdithHostCore/HostIdentity.swift",
    "Packages/ExtensionSupport/Sources/EdithExtensionSupport/Defaults.swift",
    "Extensions/usage/Services/UsageMachinesPeer.swift",
    "Extensions/studio/NativeRuntime/Sources/VideoProject.swift",
  ])
    expect(isShippingSource(path)).toBe(true);
  for (const path of [
    "Packages/Edith/Sources/Edith/Features/Dashboard/DashboardModel.swift",
    "Extensions/usage/Tests/DefaultsTests.swift",
    "Extensions/studio/NativeRuntime/vendor/Source.swift",
    "Packages/ExtensionSupport/Vendor/Source.swift",
  ])
    expect(isShippingSource(path)).toBe(false);
});

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
