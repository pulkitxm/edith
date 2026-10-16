#!/usr/bin/env bun
import { spawnSync } from "node:child_process";
import { basename } from "node:path";

const defaultScenarios = [
  { name: "help", arguments: ["--help"] },
  { name: "version", arguments: ["--version"] },
  {
    name: "completionScript",
    arguments: ["--generate-completion-script", "zsh"],
  },
  { name: "schema", arguments: ["schema"] },
];

const positiveInteger = (value, flag) => {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return number;
};

export const parseArguments = (arguments_) => {
  const options = {
    binary: "build/Build/Products/Release/ed",
    samples: 30,
    warmups: 3,
    label: "Edith CLI Release",
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const flag = arguments_[index];
    const value = arguments_[index + 1];
    if (flag === "--binary") options.binary = value;
    else if (flag === "--samples") {
      options.samples = positiveInteger(value, flag);
    } else if (flag === "--warmups") {
      options.warmups = positiveInteger(value, flag);
    } else if (flag === "--label") options.label = value;
    else throw new Error(`unknown flag: ${flag}`);
    index += 1;
  }
  if (!options.binary) throw new Error("--binary needs a path");
  if (!options.label) throw new Error("--label needs text");
  return options;
};

export const percentile = (values, percent) => {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((left, right) => left - right);
  const position = Math.max(
    0,
    Math.min(sorted.length - 1, Math.ceil((sorted.length * percent) / 100) - 1),
  );
  return sorted[position];
};

const rounded = (value) => Number(value.toFixed(3));

export const summarizeDurations = (durations) => ({
  p50: rounded(percentile(durations, 50)),
  p95: rounded(percentile(durations, 95)),
  peak: rounded(Math.max(...durations)),
});

const invoke = (binary, arguments_) => {
  const started = performance.now();
  const result = spawnSync(binary, arguments_, {
    encoding: "buffer",
    env: {
      ...process.env,
      NO_COLOR: "1",
      TERM: "dumb",
    },
    maxBuffer: 64 * 1024 * 1024,
  });
  const duration = performance.now() - started;
  if (result.error) throw result.error;
  return {
    duration,
    exitCode: result.status,
    stdoutBytes: result.stdout?.byteLength ?? 0,
    stderrBytes: result.stderr?.byteLength ?? 0,
  };
};

export const measureScenario = (
  binary,
  scenario,
  samples,
  warmups,
  invokeCommand = invoke,
) => {
  for (let index = 0; index < warmups; index += 1) {
    const result = invokeCommand(binary, scenario.arguments);
    if (result.exitCode !== 0) {
      throw new Error(`${scenario.name} warmup exited ${result.exitCode}`);
    }
  }
  const runs = [];
  for (let index = 0; index < samples; index += 1) {
    const result = invokeCommand(binary, scenario.arguments);
    if (result.exitCode !== 0) {
      throw new Error(`${scenario.name} exited ${result.exitCode}`);
    }
    runs.push({
      durationMS: rounded(result.duration),
      exitCode: result.exitCode,
      stdoutBytes: result.stdoutBytes,
      stderrBytes: result.stderrBytes,
    });
  }
  const durations = runs.map((run) => run.durationMS);
  return {
    arguments: scenario.arguments,
    samples: runs.length,
    durationMS: summarizeDurations(durations),
    stdoutBytes: runs[0].stdoutBytes,
    stderrBytes: runs[0].stderrBytes,
    raw: runs,
  };
};

const commandText = (command, arguments_) => {
  const result = spawnSync(command, arguments_, { encoding: "utf8" });
  return result.status === 0 ? result.stdout.trim() : null;
};

const environment = () => ({
  operatingSystem: commandText("sw_vers", ["-productVersion"]),
  operatingSystemBuild: commandText("sw_vers", ["-buildVersion"]),
  hardwareModel: commandText("sysctl", ["-n", "hw.model"]),
  processor: commandText("sysctl", ["-n", "machdep.cpu.brand_string"]),
  logicalProcessors: Number(commandText("sysctl", ["-n", "hw.logicalcpu"])),
  memoryBytes: Number(commandText("sysctl", ["-n", "hw.memsize"])),
  gitCommit: commandText("git", ["rev-parse", "HEAD"]),
});

export const benchmark = (options, scenarios = defaultScenarios) => {
  const results = {};
  for (const scenario of scenarios) {
    results[scenario.name] = measureScenario(
      options.binary,
      scenario,
      options.samples,
      options.warmups,
    );
  }
  return {
    schemaVersion: 1,
    capturedAt: new Date().toISOString(),
    label: options.label,
    executable: basename(options.binary),
    sampleCount: options.samples,
    warmupCount: options.warmups,
    environment: environment(),
    scenarios: results,
  };
};

const main = () => {
  try {
    const options = parseArguments(process.argv.slice(2));
    process.stdout.write(`${JSON.stringify(benchmark(options), null, 2)}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
};

if (import.meta.main) main();
