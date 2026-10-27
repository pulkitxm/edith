import { execFileSync, spawn } from "node:child_process";
import { createWriteStream, mkdirSync, readFileSync } from "node:fs";
import { availableParallelism } from "node:os";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { planSwiftTests } from "./ci-test-plan.mjs";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const checkTargets = [
  "ci-comments",
  "ci-secrets",
  "ci-duplicate-keys",
  "ci-lint",
  "ci-scripts",
  "ci-docs",
];

const ghosttyPackage = "Extensions/terminal/Native";
const localTargets = {
  "ci-extension-accounts": "ci-extension-accounts-local",
  "ci-extension-herdr-accounts": "ci-extension-herdr-accounts-local",
  "ci-extension-usage-accounts": "ci-extension-usage-accounts-local",
  "ci-extension-keep-awake": "ci-extension-keep-awake-compile",
};

export function localCIRoot(checkout) {
  const volume = checkout.match(/^\/Volumes\/[^/]+/);
  return volume ? volume[0] : "/";
}

export function parseArguments(argv) {
  const options = {
    all: false,
    base: "origin/main",
    jobs: Math.max(2, Math.floor(availableParallelism() / 4)),
    lanes: [],
    builds: false,
    checks: true,
    list: false,
  };
  for (const argument of argv) {
    if (argument === "--all") options.all = true;
    else if (argument === "--builds") options.builds = true;
    else if (argument === "--no-checks") options.checks = false;
    else if (argument === "--list") options.list = true;
    else if (argument.startsWith("--base=")) options.base = argument.slice(7);
    else if (argument.startsWith("--jobs=")) {
      options.jobs = Number(argument.slice(7));
      if (!Number.isInteger(options.jobs) || options.jobs < 1)
        throw new Error("--jobs needs a positive integer");
    } else if (argument.startsWith("--lanes="))
      options.lanes = argument.slice(8).split(",").filter(Boolean);
    else throw new Error(`Unknown argument: ${argument}`);
  }
  return options;
}

function changedPaths(base) {
  const mergeBase = execFileSync("git", ["merge-base", base, "HEAD"], {
    cwd: root,
    encoding: "utf8",
  }).trim();
  const listed = (args) =>
    execFileSync("git", args, { cwd: root, encoding: "utf8" })
      .split("\n")
      .filter(Boolean);
  return [
    ...new Set([
      ...listed(["diff", "--name-only", "--no-renames", mergeBase]),
      ...listed(["ls-files", "--others", "--exclude-standard"]),
    ]),
  ];
}

export function planLocalJobs(plan, options, definitions) {
  const jobs = [];
  if (options.checks)
    jobs.push(
      { lane: "checks", make: checkTargets, shared: [] },
      { lane: "security", make: ["ci-security", "ci-workflows"], shared: [] },
    );
  const ghostty = new Set(
    plan.include
      .filter((entry) => entry.ghostty)
      .map((entry) => entry.extension),
  );
  for (const entry of plan.include)
    jobs.push({
      lane: entry.lane,
      make: entry.targets
        .split(" ")
        .map((target) => localTargets[target] ?? target),
      shared: entry.ghostty ? [ghosttyPackage] : [],
    });
  if (options.builds) {
    const extensions = plan.include
      .map((entry) => entry.extension)
      .filter(Boolean);
    for (const id of [...new Set(extensions)]) {
      const definition = definitions.find((item) => item.id === id);
      jobs.push({
        lane: `build-${id}`,
        command: [
          "bun",
          "scripts/build-extension-package.mjs",
          id,
          "--development",
        ],
        needsHost: Boolean(definition?.systemExtensionCarrier),
        shared: ghostty.has(id) ? [ghosttyPackage] : [],
      });
    }
  }
  if (options.lanes.length === 0) return jobs;
  const wanted = new Set(options.lanes);
  const selected = jobs.filter((job) => wanted.has(job.lane));
  const missing = options.lanes.filter(
    (lane) => !selected.some((job) => job.lane === lane),
  );
  if (missing.length > 0)
    throw new Error(`Unknown lanes: ${missing.join(", ")}`);
  return selected;
}

export function sharedPackages(recipe) {
  const paths = new Set();
  for (const match of recipe.matchAll(/--package-path[= ]+"?([^\s"]+)/g))
    paths.add(match[1].replace(/\/+$/, ""));
  return [...paths];
}

function packagePaths(job, environment) {
  if (job.command) return [`Extensions/${job.command[2]}`];
  try {
    return sharedPackages(
      execFileSync("make", ["-n", ...job.make], {
        cwd: root,
        env: environment,
        encoding: "utf8",
        stdio: ["ignore", "pipe", "ignore"],
      }),
    );
  } catch {
    return [];
  }
}

function run(job, logDirectory, environment) {
  const command = job.command ?? ["make", ...job.make];
  const log = resolve(logDirectory, `${job.lane}.log`);
  const output = createWriteStream(log);
  const started = Date.now();
  return new Promise((done) => {
    const child = spawn(command[0], command.slice(1), {
      cwd: root,
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    });
    child.stdout.pipe(output);
    child.stderr.pipe(output);
    child.on("close", (code) => {
      output.end();
      done({
        lane: job.lane,
        ok: code === 0,
        seconds: Math.round((Date.now() - started) / 1000),
        log,
      });
    });
  });
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const definitions = JSON.parse(
    readFileSync(resolve(root, "Extensions/manifest.json"), "utf8"),
  );
  const paths = options.all ? [] : changedPaths(options.base);
  const plan = planSwiftTests(paths, { all: options.all });
  const jobs = planLocalJobs(plan, options, definitions);
  if (options.list) {
    for (const job of jobs)
      console.log(
        `${job.lane}\t${(job.command ?? ["make", ...job.make]).join(" ")}`,
      );
    return;
  }
  const logDirectory = resolve(root, "local/ci-logs");
  mkdirSync(logDirectory, { recursive: true });
  const environment = { ...process.env };
  environment.EDITH_MAKE_GATE = "1";
  environment.EXTENSION_SWIFT_JOBS ??= "4";
  environment.DEVELOPER_DIR ??= "/Applications/Xcode.app/Contents/Developer";
  environment.EXTENSION_CONTAINING_HOST_APP ??= "local/minimal-host/Edith.app";
  environment.EDITH_LOCAL_CI_ROOT ??= localCIRoot(root);
  if (jobs.some((job) => job.needsHost)) {
    console.log("building the host for camera packages");
    const host = await run(
      { lane: "host", make: ["host"] },
      logDirectory,
      environment,
    );
    if (!host.ok) {
      console.log(`FAIL host (${host.log})`);
      process.exitCode = 1;
      return;
    }
  }
  console.log(
    `running ${jobs.length} lanes, ${options.jobs} at a time; logs in local/ci-logs`,
  );
  for (const job of jobs)
    job.packages = [
      ...new Set([...packagePaths(job, environment), ...job.shared]),
    ];
  const queue = [...jobs];
  const results = [];
  const busy = new Set();
  let wake = () => {};
  const worker = async () => {
    while (queue.length > 0) {
      const index = queue.findIndex((job) =>
        job.packages.every((path) => !busy.has(path)),
      );
      if (index < 0) {
        await new Promise((resume) => {
          const previous = wake;
          wake = () => {
            previous();
            resume();
          };
        });
        continue;
      }
      const [job] = queue.splice(index, 1);
      for (const path of job.packages) busy.add(path);
      const result = await run(job, logDirectory, environment);
      for (const path of job.packages) busy.delete(path);
      const release = wake;
      wake = () => {};
      release();
      results.push(result);
      console.log(
        `${result.ok ? "pass" : "FAIL"} ${result.lane} ${result.seconds}s${result.ok ? "" : ` (${result.log})`}`,
      );
    }
  };
  await Promise.all(Array.from({ length: options.jobs }, worker));
  const failed = results.filter((result) => !result.ok);
  console.log(
    `${results.length - failed.length} passed, ${failed.length} failed${failed.length > 0 ? `: ${failed.map((result) => result.lane).join(" ")}` : ""}`,
  );
  if (failed.length > 0) process.exitCode = 1;
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
)
  await main();
