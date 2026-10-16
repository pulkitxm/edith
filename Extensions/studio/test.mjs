import { execFileSync, spawnSync } from "node:child_process";

const developer = process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
const shared = [
  "--package-path", ".", "--build-system", "native", "--jobs",
  process.env.EXTENSION_SWIFT_JOBS ?? "1",
  "-Xswiftc", "-plugin-path", "-Xswiftc",
  `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
];
const selection = process.argv[2] ? new RegExp(process.argv[2]) : undefined;
const listed = execFileSync("swift", ["test", "list", ...shared], {
  encoding: "utf8", stdio: ["ignore", "pipe", "inherit"],
});
const suites = [...new Set(listed.split("\n")
  .filter((name) => name.startsWith("StudioExtensionTests.") && (!selection || selection.test(name)))
  .map((name) => name.split("/")[0]))];
if (suites.length === 0) throw new Error("No Studio test suites matched.");
let testCount = 0;
for (const suite of suites) {
  const pattern = `^${suite.replaceAll(".", "\\.")}/`;
  const result = spawnSync("swift", ["test", ...shared, "--skip-build", "--no-parallel", "--filter", pattern], {
    encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], timeout: 300_000, maxBuffer: 64 * 1_024 * 1_024,
  });
  process.stdout.write(result.stdout ?? "");
  process.stderr.write(result.stderr ?? "");
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
  const outcome = /Test run with (\d+) tests? in (\d+) suites? passed/.exec((result.stdout ?? "") + (result.stderr ?? ""));
  if (!outcome || Number(outcome[1]) === 0 || Number(outcome[2]) === 0)
    throw new Error(`Studio suite ${suite} did not execute tests.`);
  testCount += Number(outcome[1]);
}
process.stdout.write(`Verified ${testCount} tests across ${suites.length} Studio suites in isolated test processes.\n`);
