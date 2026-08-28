import { describe, expect, test } from "bun:test";

const harness = `
set -euo pipefail
source scripts/build-jobs.sh
xcodebuild() { printf 'xcode:%s\\n' "$@"; }
swift_stub() { printf 'swift:%s\\n' "$@"; }
jobs="\${EDITH_BUILD_JOBS:-}"
validate_build_jobs "$jobs"
xcodebuild_with_jobs "$jobs" -project app
swift_build_with_jobs "$jobs" swift_stub --package-path package
`;

function run(jobs) {
  const environment = { ...process.env };
  if (jobs === undefined) {
    delete environment.EDITH_BUILD_JOBS;
  } else {
    environment.EDITH_BUILD_JOBS = jobs;
  }
  return Bun.spawnSync(["/bin/bash", "-u", "-c", harness], {
    cwd: process.cwd(),
    env: environment,
  });
}

describe("build job limits", () => {
  test("the unset default uses native command parallelism under nounset", () => {
    const result = run(undefined);

    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString()).toBe(
      "xcode:-project\nxcode:app\nswift:build\nswift:--package-path\nswift:package\n",
    );
  });

  test("an explicit value bounds Xcode and Swift builds", () => {
    const result = run("2");

    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString()).toBe(
      "xcode:-jobs\nxcode:2\nxcode:-project\nxcode:app\nswift:build\nswift:--jobs\nswift:2\nswift:--package-path\nswift:package\n",
    );
  });

  test("invalid values fail before either build starts", () => {
    for (const value of ["0", "two", "-1"]) {
      const result = run(value);

      expect(result.exitCode).toBe(1);
      expect(result.stdout.toString()).toBe("");
      expect(result.stderr.toString()).toContain(
        "EDITH_BUILD_JOBS must be a positive integer",
      );
    }
  });
});
