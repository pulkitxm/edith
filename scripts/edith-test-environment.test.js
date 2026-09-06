import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";

function runPython(source, environment = {}) {
  return JSON.parse(
    execFileSync("python3", ["-B", "-c", source], {
      encoding: "utf8",
      timeout: 10000,
      env: { ...process.env, ...environment },
    }),
  );
}

test("daemon fixtures replace every inherited production storage and service path", () => {
  const values = runPython(
    `import json, pathlib, tempfile
from scripts.edith_test_environment import isolated_test_environment
with tempfile.TemporaryDirectory() as folder:
    root = pathlib.Path(folder)
    values = isolated_test_environment(root, 'com.pulkit.edith.test.fixture')
    print(json.dumps({key: values[key] for key in [
        'EDITH_DATA_ROOT', 'EDITH_CLOUD_ROOT', 'EDITH_DATABASE_HOME',
        'EDITH_DATABASE_KEYCHAIN_SERVICE', 'EDITH_AGENT_MACH_SERVICE',
        'EDITH_USAGE_SOURCE_HOME', 'EDITH_PROVIDER_KEYCHAIN_SERVICE',
        'EDITH_SHARED_DEFAULTS_SUITE', 'EDITH_HELPER_DEFAULTS_SUITE'
    ]}))`,
    {
      EDITH_DATA_ROOT: "/production/data",
      EDITH_CLOUD_ROOT: "/production/cloud",
      EDITH_DATABASE_HOME: "/production/home",
      EDITH_DATABASE_KEYCHAIN_SERVICE: "com.pulkit.edith.database",
      EDITH_USAGE_SOURCE_HOME: "/production/source-home",
      EDITH_PROVIDER_KEYCHAIN_SERVICE: "production-provider-credentials",
      EDITH_AGENT_MACH_SERVICE: "com.pulkit.edith.agent",
      EDITH_SHARED_DEFAULTS_SUITE: "com.pulkit.edith.shared",
      EDITH_HELPER_DEFAULTS_SUITE: "com.pulkit.edith.helper",
    },
  );
  for (const key of [
    "EDITH_DATA_ROOT",
    "EDITH_CLOUD_ROOT",
    "EDITH_DATABASE_HOME",
    "EDITH_USAGE_SOURCE_HOME",
  ]) {
    expect(values[key]).not.toContain("/production/");
  }
  for (const key of [
    "EDITH_DATABASE_KEYCHAIN_SERVICE",
    "EDITH_PROVIDER_KEYCHAIN_SERVICE",
    "EDITH_AGENT_MACH_SERVICE",
    "EDITH_SHARED_DEFAULTS_SUITE",
    "EDITH_HELPER_DEFAULTS_SUITE",
  ]) {
    expect(values[key]).toStartWith("com.pulkit.edith.test.fixture");
  }
});

test("daemon fixtures reject production service names and unsafe roots", () => {
  const results = runPython(`import json, pathlib, tempfile
from scripts.edith_test_environment import isolated_test_environment
results = []
with tempfile.TemporaryDirectory() as folder:
    root = pathlib.Path(folder)
    link = root / 'alias'
    link.symlink_to(root, target_is_directory=True)
    for path, service in [(root, 'com.pulkit.edith.agent'),
                          (pathlib.Path('.'), 'com.pulkit.edith.test.fixture'),
                          (link, 'com.pulkit.edith.test.fixture')]:
        try:
            isolated_test_environment(path, service)
            results.append(False)
        except ValueError:
            results.append(True)
print(json.dumps(results))`);
  expect(results).toEqual([true, true, true]);
});

test("daemon fixtures use an explicitly selected release build directory", () => {
  const result = runPython(
    `import json
from scripts.edith_test_environment import test_build_directory
print(json.dumps(str(test_build_directory('/fixture/repo'))))`,
    { EDITH_TEST_BUILD_DIR: "/fixture/release" },
  );
  expect(result).toBe("/fixture/release");
});
