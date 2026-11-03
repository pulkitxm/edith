import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";

test("normal Marketplace CI expands one complete serial suite with numeric jobs", () => {
  const make =
    process.platform === "darwin"
      ? execFileSync("xcrun", ["--find", "gnumake"], {
          encoding: "utf8",
        }).trim()
      : "/usr/bin/make";
  const output = execFileSync(
    make,
    [
      "--dry-run",
      "ci-marketplace-runtime",
      "DEVELOPER_DIR=/synthetic/SelectedXcode.app/Contents/Developer",
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        EDITH_MAKE_GATE: "skip",
        EXTENSION_SWIFT_JOBS: "3",
        DEVELOPER_DIR: "/synthetic/SelectedXcode.app/Contents/Developer",
      },
    },
  );
  const commands = output
    .split("\n")
    .filter((line) => line.startsWith("swift test "));
  expect(commands).toEqual([
    'swift test --package-path Packages/ExtensionMarketplace --build-system native --no-parallel --jobs 3 -Xswiftc -plugin-path -Xswiftc "/synthetic/SelectedXcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"',
  ]);
  expect(commands[0]).not.toContain("--filter");
  expect(commands[0]).not.toContain("--skip");
  expect(output).toContain("swift format lint --strict");
});
