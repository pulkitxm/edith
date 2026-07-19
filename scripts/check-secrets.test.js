import { expect, test } from "bun:test";
import { RULES, scanText } from "./check-secrets.mjs";

const licenseKey = ["EDITH", "ABCD", "EFGH", "IJKL", "MNOP"].join("-");
const refreshCredential = "edithrc_".concat("Zx9", "q".repeat(17));
const pemHeader = ["-----BEGIN", "PRIVATE", "KEY-----"].join(" ");
const seedLine = 'let seed = "'.concat("A".repeat(43), "=", '"');

test("rules cover the four secret shapes", () => {
  expect(RULES.map((r) => r.name)).toEqual([
    "license key",
    "refresh credential",
    "private key block",
    "ed25519 seed assignment",
  ]);
});

test("license key fires in a non-exempt path", () => {
  const findings = scanText(
    `let key = "${licenseKey}"`,
    "apps/macos/Sources/License.swift",
  );
  expect(findings).toEqual(["apps/macos/Sources/License.swift:1: license key"]);
});

test("refresh credential fires", () => {
  const findings = scanText(`token=${refreshCredential}`, "scripts/deploy.mjs");
  expect(findings).toEqual(["scripts/deploy.mjs:1: refresh credential"]);
});

test("private key block fires with no allowlist escape", () => {
  const findings = scanText(`${pemHeader}\nabc`, "tests/fixtures/key.pem");
  expect(findings).toEqual(["tests/fixtures/key.pem:1: private key block"]);
});

test("ed25519 seed assignment fires", () => {
  const findings = scanText(
    `import Foundation\n${seedLine}`,
    "apps/macos/Sources/Crypto.swift",
  );
  expect(findings).toEqual([
    "apps/macos/Sources/Crypto.swift:2: ed25519 seed assignment",
  ]);
});

test("ordinary code produces no findings", () => {
  const src = [
    'let name = "EDITH"',
    "let sum = seed + offset",
    'let url = "https://example.com/keys"',
    'let short = "edithrc_abc"',
  ].join("\n");
  expect(scanText(src, "apps/macos/Sources/App.swift")).toEqual([]);
});

test("XXXX placeholder license key is allowed", () => {
  const src = 'let placeholder = "EDITH-XXXX-XXXX-XXXX-XXXX"';
  expect(scanText(src, "apps/macos/Sources/Docs.swift")).toEqual([]);
});

test("license key inside Tests/ paths is exempt", () => {
  const src = `let key = "${licenseKey}"`;
  expect(scanText(src, "apps/macos/Tests/LicenseTests.swift")).toEqual([]);
  expect(scanText(src, "tests/license.test.js")).toEqual([]);
});

test("refresh credential inside Tests/ paths is exempt", () => {
  const src = `token=${refreshCredential}`;
  expect(scanText(src, "apps/macos/Tests/TokenTests.swift")).toEqual([]);
  expect(scanText(src, "tests/token.test.js")).toEqual([]);
});

test("binary content with NUL bytes is skipped", () => {
  expect(scanText(`\u0000${licenseKey}`, "assets/blob.bin")).toEqual([]);
});
