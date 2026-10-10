import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const make =
  process.platform === "darwin"
    ? execFileSync("xcrun", ["--find", "gnumake"], { encoding: "utf8" }).trim()
    : "/usr/bin/make";

const manifest = JSON.parse(await readFile("Extensions/manifest.json", "utf8"));
const targets = [
  ...new Set(manifest.flatMap(({ testTargets }) => testTargets ?? [])),
];
const makefile = await readFile("Makefile", "utf8");

async function fixture(body) {
  const root = await mkdtemp(join(tmpdir(), "native-make-contract-"));
  try {
    const tools = join(root, "tools"),
      developer = join(root, "Developer");
    await mkdir(tools);
    await mkdir(join(developer, "usr/bin"), { recursive: true });
    await writeFile(join(developer, "usr/bin/xcodebuild"), "", { mode: 0o700 });
    await writeFile(join(root, "Makefile"), makefile);
    await mkdir(join(root, "Extensions/usage"), { recursive: true });
    await writeFile(
      join(root, "Extensions/usage/Makefile"),
      await readFile("Extensions/usage/Makefile"),
    );
    await mkdir(join(root, "Extensions/studio"), { recursive: true });
    await writeFile(
      join(root, "Extensions/studio/Makefile"),
      await readFile("Extensions/studio/Makefile"),
    );
    const log = join(root, "calls");
    for (const tool of ["python3", "swift", "bun", "bash"])
      await writeFile(
        join(tools, tool),
        `#!/bin/sh\nprintf '%s\\n' '${tool}' >> "$NATIVE_MAKE_CALLS"\nexit 0\n`,
        { mode: 0o700 },
      );
    await writeFile(
      join(tools, "xcode-select"),
      '#!/bin/sh\nprintf "%s\\n" "$NATIVE_MAKE_DEVELOPER"\n',
      { mode: 0o700 },
    );
    await writeFile(
      join(tools, "xcrun"),
      '#!/bin/sh\nprintf "%s\\n" "/synthetic-sdk"\n',
      { mode: 0o700 },
    );
    const environment = {
      ...process.env,
      PATH: `${tools}:/usr/bin:/bin`,
      NATIVE_MAKE_CALLS: log,
      NATIVE_MAKE_DEVELOPER: developer,
    };
    for (const key of [
      "EDITH_MAKE_GATE",
      "EXTENSION_SWIFT_JOBS",
      "DEVELOPER_DIR",
      "MAKEFLAGS",
      "MFLAGS",
      "MAKEOVERRIDES",
      "MAKELEVEL",
    ])
      delete environment[key];
    await body({ root, developer, log, environment });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("every declared native owner enters only the resource gate at the outer Make layer", async () => {
  expect(targets.length).toBeGreaterThan(20);
  await fixture(async ({ root, log, environment }) => {
    for (const target of targets) {
      await writeFile(log, "");
      execFileSync(make, [target], {
        cwd: root,
        env: environment,
        encoding: "utf8",
        timeout: 5000,
      });
      expect((await readFile(log, "utf8")).trim().split("\n")).toEqual([
        "python3",
      ]);
    }
  });
});

test("real inner Make expansion retains selected compiler and valid jobs for all standalone native suites", async () => {
  await fixture(async ({ root, developer, environment }) => {
    const output = execFileSync(make, ["-n", ...targets], {
      cwd: root,
      env: { ...environment, EDITH_MAKE_GATE: "skip" },
      encoding: "utf8",
      timeout: 10000,
      maxBuffer: 1024 ** 2,
    });
    const swiftCommands = output
      .split("\n")
      .filter(
        (line) => line.includes("swift test ") || line.includes("swift build "),
      );
    expect(swiftCommands.length).toBeGreaterThan(20);
    for (const line of swiftCommands) {
      expect(line).toMatch(/--jobs [1-9][0-9]*(?:\s|$)/);
      if (line.includes("-plugin-path"))
        expect(line).toContain(
          `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
        );
    }
    expect(output).toContain("--package-path Extensions/clipboard");
    expect(output).toContain("--package-path Extensions/terminal");
    expect(output).toContain("--package-path Extensions/herdr");
    expect(output).toContain("--package-path Extensions/notchShelf");
    expect(output).not.toMatch(/--jobs\s+-/);
  });
});
