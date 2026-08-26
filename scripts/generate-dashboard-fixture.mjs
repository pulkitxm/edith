#!/usr/bin/env bun
import { writeFileSync } from "node:fs";

const positiveInteger = (value, flag) => {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1) {
    throw new Error(`${flag} must be a positive integer`);
  }
  return number;
};

export const parseArguments = (arguments_) => {
  const options = {
    output: null,
    days: 730,
    sources: 50,
    models: 100,
    projects: 10_000,
    seed: 7_614,
  };
  for (let index = 0; index < arguments_.length; index += 1) {
    const flag = arguments_[index];
    const value = arguments_[index + 1];
    if (flag === "--output") options.output = value;
    else if (flag === "--days") options.days = positiveInteger(value, flag);
    else if (flag === "--sources") {
      options.sources = positiveInteger(value, flag);
    } else if (flag === "--models") {
      options.models = positiveInteger(value, flag);
    } else if (flag === "--projects") {
      options.projects = positiveInteger(value, flag);
    } else if (flag === "--seed") options.seed = positiveInteger(value, flag);
    else throw new Error(`unknown flag: ${flag}`);
    index += 1;
  }
  if (!options.output) throw new Error("--output needs a path");
  return options;
};

const randomGenerator = (seed) => {
  let value = seed >>> 0;
  return () => {
    value = (Math.imul(value, 1_664_525) + 1_013_904_223) >>> 0;
    return value / 4_294_967_296;
  };
};

const rounded = (value, places = 6) => Number(value.toFixed(places));

const isoDay = (index) => {
  const date = new Date(Date.UTC(2024, 0, 1 + index));
  return date.toISOString().slice(0, 10);
};

const modelRow = (modelName, random) => {
  const inputTokens = Math.floor(500 + random() * 50_000);
  const outputTokens = Math.floor(100 + random() * 12_000);
  const cacheCreationTokens = Math.floor(random() * 8_000);
  const cacheReadTokens = Math.floor(random() * 40_000);
  return {
    modelName,
    inputTokens,
    outputTokens,
    cacheCreationTokens,
    cacheReadTokens,
    cost: rounded(
      inputTokens * 0.000_003 +
        outputTokens * 0.000_015 +
        cacheCreationTokens * 0.000_003_75 +
        cacheReadTokens * 0.000_000_3,
    ),
  };
};

const projectRow = (index, day, sourceIDs, modelIDs, random) => {
  const repository = index % Math.max(1, Math.ceil(index / 4_000) + 120);
  const source = sourceIDs[index % sourceIDs.length];
  const model = modelIDs[index % modelIDs.length];
  const tokens = Math.floor(1_000 + random() * 200_000);
  const cost = rounded(tokens * (0.000_001 + random() * 0.000_004));
  const firstTs = Date.parse(`${day}T08:00:00Z`) / 1_000 + (index % 28_800);
  return {
    projectName: `Synthetic Project ${repository}`,
    repositoryID: `repository-${repository}`,
    repositoryName: `synthetic-${repository}`,
    repositoryURL: `https://example.invalid/synthetic/${repository}`,
    folderName: `workspace-${index % 400}`,
    path: `/synthetic/workspaces/${index % 400}`,
    machineName: `Fixture Mac ${index % 12}`,
    machineID: `00000000-0000-4000-8000-${String(index % 12).padStart(12, "0")}`,
    tokens,
    cost,
    bySource: {
      [source]: {
        tokens,
        cost,
        byModel: { [model]: { tokens, cost } },
      },
    },
    chats: [
      {
        id: `chat-${index}`,
        path: `/synthetic/chats/${index}.jsonl`,
        title: `Synthetic task ${index}`,
        tokens,
        cost,
        source,
        firstTs,
        lastTs: firstTs + 900 + (index % 3_600),
      },
    ],
    worktrees: [],
  };
};

export const generateDashboardFixture = ({
  days,
  sources,
  models,
  projects,
  seed,
}) => {
  const random = randomGenerator(seed);
  const sourceIDs = Array.from({ length: sources }, (_, index) => `source-${index}`);
  const modelIDs = Array.from({ length: models }, (_, index) => `model-${index}`);
  const sourceMeta = Object.fromEntries(
    sourceIDs.map((id, index) => [
      id,
      {
        label: `Fixture Source ${index}`,
        tool: `fixture-${index % 8}`,
        machine: `Fixture Mac ${index % 12}`,
        machineID: `00000000-0000-4000-8000-${String(index % 12).padStart(12, "0")}`,
      },
    ]),
  );
  const daily = [];
  let projectIndex = 0;
  for (let dayIndex = 0; dayIndex < days; dayIndex += 1) {
    const period = isoDay(dayIndex);
    const bySource = {};
    for (let sourceIndex = 0; sourceIndex < sources; sourceIndex += 1) {
      const firstModel = (dayIndex * sources + sourceIndex) % models;
      bySource[sourceIDs[sourceIndex]] = [
        modelRow(modelIDs[firstModel], random),
        modelRow(modelIDs[(firstModel + 1) % models], random),
      ];
    }
    const remainingDays = days - dayIndex;
    const remainingProjects = projects - projectIndex;
    const dayProjectCount = Math.ceil(remainingProjects / remainingDays);
    const projectRows = [];
    for (let offset = 0; offset < dayProjectCount; offset += 1) {
      projectRows.push(
        projectRow(projectIndex, period, sourceIDs, modelIDs, random),
      );
      projectIndex += 1;
    }
    const hours = Array.from({ length: 24 }, (_, hour) => ({
      tokens: Math.floor(random() * 200_000),
      cost: rounded(random() * 4),
      bySource: {},
      byPath: {},
      hour,
    }));
    daily.push({ period, bySource, projects: projectRows, hours });
  }
  const totals = daily.reduce(
    (result, day) => {
      for (const rows of Object.values(day.bySource)) {
        for (const row of rows) {
          result.tokens +=
            row.inputTokens +
            row.outputTokens +
            row.cacheCreationTokens +
            row.cacheReadTokens;
          result.cost += row.cost;
        }
      }
      return result;
    },
    { tokens: 0, cost: 0 },
  );
  totals.cost = rounded(totals.cost);
  return {
    schemaVersion: 1,
    generatedAt: "2026-08-26T00:00:00Z",
    fixture: {
      seed,
      days,
      sources,
      models,
      projects,
    },
    sources: sourceIDs,
    defaultSources: sourceIDs,
    sourceMeta,
    totals,
    machines: [],
    daily,
    sessions: [],
  };
};

const main = () => {
  try {
    const options = parseArguments(process.argv.slice(2));
    const fixture = generateDashboardFixture(options);
    writeFileSync(options.output, `${JSON.stringify(fixture)}\n`);
    process.stdout.write(
      `${JSON.stringify({ output: options.output, ...fixture.fixture })}\n`,
    );
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exit(2);
  }
};

if (import.meta.main) main();
