import { afterEach, expect, test } from "bun:test";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const roots = [];
const approval = JSON.parse(
  readFileSync(resolve("scripts/trusted-package-plugins.json"), "utf8"),
)[0];
const packageLock = "Packages/Edith/Package.resolved";
const appLock =
  "edth.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved";

afterEach(() => {
  for (const root of roots.splice(0))
    rmSync(root, { recursive: true, force: true });
});

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "package-plugin-approval-"));
  roots.push(root);
  const home = join(root, "home");
  const destination = join(
    home,
    "Library/org.swift.swiftpm/security/plugins.json",
  );
  mkdirSync(dirname(destination), { recursive: true });
  mkdirSync(join(root, "scripts"));
  for (const name of [
    "approve-package-plugins.py",
    "trusted-package-plugins.json",
  ])
    copyFileSync(resolve("scripts", name), join(root, "scripts", name));
  const setPin = (path, revision) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(
      join(root, path),
      JSON.stringify({
        pins: [{ identity: "swiftterm", state: { revision } }],
      }),
    );
  };
  setPin(packageLock, approval.fingerprint);
  setPin(appLock, approval.fingerprint);
  const run = () =>
    Bun.spawnSync(
      ["python3", join(root, "scripts/approve-package-plugins.py")],
      {
        env: { ...process.env, HOME: home },
        stdout: "pipe",
        stderr: "pipe",
      },
    );
  return { root, destination, setPin, run };
}

test("approval preserves existing entries and remains idempotent", () => {
  const sample = fixture();
  const previous = [
    { fingerprint: "older", packageIdentity: "other", targetName: "Existing" },
    { ...approval, fingerprint: "previously-approved", metadata: "preserve" },
  ];
  writeFileSync(sample.destination, JSON.stringify(previous));
  expect(sample.run().exitCode).toBe(0);
  expect(JSON.parse(readFileSync(sample.destination, "utf8"))).toEqual([
    ...previous,
    approval,
  ]);
  const saved = statSync(sample.destination).mtimeMs;
  expect(sample.run().exitCode).toBe(0);
  expect(statSync(sample.destination).mtimeMs).toBe(saved);
});

for (const lock of [packageLock, appLock]) {
  test(`an unreviewed revision in ${lock} never gains approval`, () => {
    const sample = fixture();
    sample.setPin(lock, "a".repeat(40));
    const result = sample.run();
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("differs from its reviewed");
    expect(existsSync(sample.destination)).toBe(false);
  });
}

test("malformed existing approval data is preserved exactly", () => {
  const sample = fixture();
  for (const content of ["{invalid", '{"unexpected":"format"}']) {
    writeFileSync(sample.destination, content);
    expect(sample.run().exitCode).toBe(1);
    expect(readFileSync(sample.destination, "utf8")).toBe(content);
  }
});

test("a clean Xcode configuration receives only the reviewed record", () => {
  const sample = fixture();
  expect(sample.run().exitCode).toBe(0);
  expect(JSON.parse(readFileSync(sample.destination, "utf8"))).toEqual([
    approval,
  ]);
});
