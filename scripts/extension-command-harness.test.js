import { expect, test } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const make =
  process.platform === "darwin"
    ? execFileSync("xcrun", ["--find", "gnumake"], { encoding: "utf8" }).trim()
    : "/usr/bin/make";
const makefile = await readFile("Makefile", "utf8");
const runner = resolve("scripts/test-extension-commands.mjs");

async function fixture(body) {
  const root = await mkdtemp(join(tmpdir(), "command-harness-contract-"));
  try {
    const tools = join(root, "tools");
    const developer = join(root, "Developer");
    const products = join(root, "native arm64 products/debug");
    const log = join(root, "calls");
    await mkdir(tools);
    await mkdir(join(developer, "usr/bin"), { recursive: true });
    await writeFile(join(developer, "usr/bin/xcodebuild"), "", { mode: 0o700 });
    await writeFile(join(root, "Makefile"), makefile);
    await writeFile(log, "");
    await writeFile(
      join(tools, "xcode-select"),
      '#!/bin/sh\nprintf "%s\\n" "$COMMAND_DEVELOPER"\n',
      { mode: 0o700 },
    );
    await writeFile(
      join(tools, "swift"),
      `#!/bin/sh
printf '%s\\n' swift "$@" END >> "$COMMAND_CALLS"
case " $* " in
  *" --show-bin-path "*)
    if [ "$COMMAND_FAILURE" = query ]; then exit 19; fi
    if [ "$COMMAND_FAILURE" != empty ]; then printf '%s\\n' "$COMMAND_PRODUCTS"; fi
    ;;
  *)
    if [ "$COMMAND_FAILURE" = build ]; then exit 17; fi
    if [ "$COMMAND_FAILURE" != missing ]; then
      mkdir -p "$COMMAND_PRODUCTS"
      printf '%s\\n' fixture > "$COMMAND_PRODUCTS/HostCommandHarness"
      if [ "$COMMAND_FAILURE" != nonexecutable ]; then chmod 700 "$COMMAND_PRODUCTS/HostCommandHarness"; fi
    fi
    ;;
esac
`,
      { mode: 0o700 },
    );
    await writeFile(
      join(tools, "bun"),
      '#!/bin/sh\nprintf \'%s\\n\' bun "$@" END >> "$COMMAND_CALLS"\n',
      { mode: 0o700 },
    );
    const environment = {
      ...process.env,
      PATH: `${tools}:/usr/bin:/bin`,
      EDITH_MAKE_GATE: "skip",
      EXTENSION_SWIFT_JOBS: "1",
      COMMAND_CALLS: log,
      COMMAND_DEVELOPER: developer,
      COMMAND_PRODUCTS: products,
      COMMAND_FAILURE: "",
    };
    for (const key of [
      "DEVELOPER_DIR",
      "MAKEFLAGS",
      "MFLAGS",
      "MAKEOVERRIDES",
      "MAKELEVEL",
    ])
      delete environment[key];
    const run = (failure = "") =>
      spawnSync(make, ["ci-extension-commands"], {
        cwd: root,
        env: { ...environment, COMMAND_FAILURE: failure },
        encoding: "utf8",
        timeout: 5000,
      });
    const calls = async () =>
      (await readFile(log, "utf8"))
        .split("END\n")
        .filter(Boolean)
        .map((call) => call.trim().split("\n"));
    await body({ run, calls, products, developer });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("standalone command tests build once and pass the discovered native executable path", async () => {
  await fixture(async ({ run, calls, products, developer }) => {
    const result = run();
    expect(result.status, result.stderr).toBe(0);
    expect(await calls()).toEqual([
      [
        "swift",
        "build",
        "--package-path",
        "Packages/EdithHost",
        "--build-system",
        "native",
        "--configuration",
        "debug",
        "--jobs",
        "1",
        "--product",
        "HostCommandHarness",
        "-Xswiftc",
        "-plugin-path",
        "-Xswiftc",
        `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
      ],
      [
        "swift",
        "build",
        "--package-path",
        "Packages/EdithHost",
        "--build-system",
        "native",
        "--configuration",
        "debug",
        "--show-bin-path",
      ],
      [
        "bun",
        "scripts/test-extension-commands.mjs",
        join(products, "HostCommandHarness"),
      ],
    ]);
  });
});

test("failed harness compilation prevents bin discovery and command execution", async () => {
  await fixture(async ({ run, calls }) => {
    expect(run("build").status).not.toBe(0);
    const actual = await calls();
    expect(actual.length).toBe(1);
    expect(actual[0]).toContain("HostCommandHarness");
  });
});

for (const failure of ["query", "empty", "missing", "nonexecutable"])
  test(`invalid native product discovery (${failure}) prevents command execution`, async () => {
    await fixture(async ({ run, calls }) => {
      expect(run(failure).status).not.toBe(0);
      const actual = await calls();
      expect(actual.length).toBe(2);
      expect(actual[1]).toContain("--show-bin-path");
      expect(actual.some(([tool]) => tool === "bun")).toBe(false);
    });
  });

test("command runner rejects missing and relative harness paths before preparing fixtures", () => {
  for (const arguments_ of [
    [],
    ["Packages/EdithHost/.build/debug/HostCommandHarness"],
  ]) {
    const result = spawnSync(process.execPath, [runner, ...arguments_], {
      encoding: "utf8",
      timeout: 5000,
    });
    expect(result.status).not.toBe(0);
    expect(result.stderr).toContain(
      "Pass the absolute HostCommandHarness path",
    );
  }
});
