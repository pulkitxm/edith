import { expect, test } from "bun:test";
import { parseArguments, planLocalJobs } from "./ci-local.mjs";

const plan = {
  include: [
    { lane: "host-runtime", targets: "ci-host ci-marketplace-runtime" },
    {
      lane: "extension-virtualCamera",
      extension: "virtualCamera",
      targets: "ci-extension-camera",
    },
    {
      lane: "extension-usage",
      extension: "usage",
      targets: "ci-extension-usage-native",
    },
  ],
};
const definitions = [
  { id: "virtualCamera", systemExtensionCarrier: {} },
  { id: "usage" },
];

test("local CI runs the same make targets as each CI lane after the checks", () => {
  const jobs = planLocalJobs(plan, parseArguments([]), definitions);
  expect(jobs.map((job) => job.lane)).toEqual([
    "checks",
    "host-runtime",
    "extension-virtualCamera",
    "extension-usage",
  ]);
  expect(jobs[1].make).toEqual(["ci-host", "ci-marketplace-runtime"]);
});

test("builds add one development package per planned extension and mark camera hosts", () => {
  const jobs = planLocalJobs(
    plan,
    parseArguments(["--builds", "--no-checks"]),
    definitions,
  );
  const builds = jobs.filter((job) => job.lane.startsWith("build-"));
  expect(builds.map((job) => [job.lane, job.needsHost])).toEqual([
    ["build-virtualCamera", true],
    ["build-usage", false],
  ]);
  expect(builds[1].command).toEqual([
    "bun",
    "scripts/build-extension-package.mjs",
    "usage",
    "--development",
  ]);
});

test("selected lanes rerun only those lanes and reject unknown names", () => {
  const options = parseArguments(["--lanes=extension-usage", "--jobs=6"]);
  expect(options.jobs).toBe(6);
  expect(
    planLocalJobs(plan, options, definitions).map((job) => job.lane),
  ).toEqual(["extension-usage"]);
  expect(() =>
    planLocalJobs(plan, parseArguments(["--lanes=missing"]), definitions),
  ).toThrow("Unknown lanes: missing");
  expect(() => parseArguments(["--jobs=0"])).toThrow();
});
