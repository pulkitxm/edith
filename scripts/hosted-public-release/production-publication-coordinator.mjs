import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { verifiedLineage } from "./evidence.mjs";
import {
  productionCatalogBinding,
  productionCatalogChannel,
  productionCatalogMessage,
  productionObserverEnvironment,
  productionReadonlyEnvironment,
  validateProductionCatalogMessage,
} from "./production-catalog-channel.mjs";

import { productionPublicationBudget } from "./production-publication-budget.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
export async function coordinateProductionCatalog(
  channel,
  binding,
  promote,
  isActive,
) {
  const milestone = await channel.read();
  validateProductionCatalogMessage(milestone, "host-restored", binding);
  assert(isActive());
  await promote();
  assert(isActive());
  await channel.write(productionCatalogMessage("catalog-promoted", binding));
}
export function completedProductionCohortRequest(
  template,
  identity,
  record,
  measured,
) {
  assert.equal(template.catalogs.current, null);
  assert.equal(template.source, identity.source);
  assert.equal(template.application, "/Applications/Edith.app");
  assert.equal(record.id, "keepAwake");
  assert.equal(record.version, "1.0.1");
  assert.equal(template.packages.current, null);
  assert.equal(measured.source, template.source);
  for (const [key, actual] of Object.entries({
    id: record.id,
    version: record.version,
    archiveSHA256: record.sha256,
    archiveURL: record.downloadURL,
    sourceFingerprint: record.sourceFingerprint,
    downloadBytes: record.downloadBytes,
    installedBytes: record.installedBytes,
    hostABI: record.hostABI,
    architecture: record.architecture,
    minimumSystemVersion: record.minimumSystemVersion,
    dependencies: record.dependencies,
  }))
    assert.deepEqual(measured[key], actual);
  for (const key of ["revision", "sha256", "bytes"])
    assert.equal(template.catalogs.previous[key], identity.previous[key]);
  const request = {
    ...template,
    packages: { previous: template.packages.previous, current: measured },
    catalogs: {
      previous: template.catalogs.previous,
      current: {
        revision: identity.candidate.revision,
        sha256: identity.candidate.sha256,
        bytes: identity.candidate.bytes,
        signatureVerified: true,
        selectedVersion: record.version,
        selectedArchiveSHA256: record.sha256,
      },
    },
  };
  const text = JSON.stringify(request);
  productionCatalogBinding(text, identity);
  return text;
}
async function runObserver(text, binding, remaining) {
  const child = spawn(
    process.execPath,
    [
      join(
        root,
        "scripts/hosted-public-release/production-coordinated-runner.mjs",
      ),
    ],
    {
      cwd: root,
      env: productionObserverEnvironment(process.env, text, binding),
      stdio: ["ignore", "inherit", "inherit", "pipe", "pipe"],
    },
  );
  const channel = productionCatalogChannel(child.stdio[4], child.stdio[3]);
  let completed = false;
  let timedOut = false;
  let terminate;
  let timeout;
  let launchError;
  const joined = new Promise((resolve_, reject) => {
    child.once("error", (error) => {
      launchError = error;
    });
    child.once("close", (code, signal) => {
      completed = true;
      clearTimeout(timeout);
      clearTimeout(terminate);
      if (code === 0 && signal === null && !timedOut && !launchError)
        resolve_();
      else reject(new Error("Owned production observer did not complete"));
    });
  });
  joined.catch(() => {});
  const retire = () => {
    if (completed || child.exitCode !== null || child.signalCode !== null)
      return;
    child.kill("SIGTERM");
    terminate ??= setTimeout(() => {
      if (!completed && child.exitCode === null && child.signalCode === null)
        child.kill("SIGKILL");
    }, 5000);
  };
  try {
    timeout = setTimeout(() => {
      timedOut = true;
      retire();
    }, remaining());
  } catch (error) {
    timedOut = true;
    retire();
    await joined.catch(() => {});
    channel.close();
    throw error;
  }
  return {
    channel,
    joined,
    isActive: () => {
      try {
        remaining();
        return (
          !completed &&
          !timedOut &&
          child.exitCode === null &&
          child.signalCode === null
        );
      } catch {
        timedOut = true;
        retire();
        return false;
      }
    },
    retire,
  };
}
export function parseProductionCohortTemplate(text, environment) {
  assert(
    typeof text === "string" &&
      Buffer.byteLength(text) > 0 &&
      Buffer.byteLength(text) <= 65536,
  );
  const parsed = execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.preparation_template(sys.stdin.read())))",
      join(root, "scripts/hosted-public-release/production-cohort.py"),
    ],
    {
      cwd: root,
      env: productionReadonlyEnvironment(environment),
      input: text,
      timeout: 60000,
      maxBuffer: 65536,
    },
  );
  return JSON.parse(parsed.toString());
}
export function admitProductionPublicationEnvironment(environment, source) {
  for (const [key, value] of Object.entries({
    GITHUB_ACTIONS: "true",
    RUNNER_ENVIRONMENT: "github-hosted",
    RUNNER_OS: "macOS",
    GITHUB_REPOSITORY: "pulkitxm/edith",
    GITHUB_REPOSITORY_ID: "1289153439",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    GITHUB_REF: "refs/heads/main",
    PUBLIC_RELEASE_VERIFICATION: "1",
  }))
    assert.equal(environment[key], value);
  assert(["65671483", "320458784"].includes(environment.GITHUB_ACTOR_ID));
  assert(
    environment.GH_TOKEN &&
      environment.GITHUB_TOKEN &&
      environment.GH_TOKEN !== environment.GITHUB_TOKEN,
  );
  assert(environment.EXTENSION_CATALOG_PRIVATE_KEY);
  assert.equal(environment.GITHUB_SHA, source);
  for (const key of [
    "NODE_OPTIONS",
    "NODE_PATH",
    "PYTHONPATH",
    "PYTHONHOME",
    "CFFIXED_USER_HOME",
    "SSH_AUTH_SOCK",
  ])
    assert.equal(environment[key], undefined);
  assert(!Object.keys(environment).some((key) => key.startsWith("EDITH_")));
}
export function admitStagedPublicationAPI(namespace) {
  assert(namespace && typeof namespace === "object");
  for (const name of [
    "publishExtensions",
    "stagedExtensionPublication",
    "promoteStagedExtensionPublication",
  ])
    assert.equal(
      typeof namespace[name],
      "function",
      "Reviewed staged publication APIs are required",
    );
  return namespace;
}
export async function publishCoordinatedProductionUpdate(templateText) {
  const remaining = productionPublicationBudget();
  const publication = admitStagedPublicationAPI(
    await import("../extension-publish.mjs"),
  );
  assert.equal(process.platform, "darwin");
  assert.equal(process.arch, "arm64");
  admitProductionPublicationEnvironment(process.env, process.env.GITHUB_SHA);
  assert(
    typeof templateText === "string" &&
      Buffer.byteLength(templateText) <= 65536,
  );
  const template = parseProductionCohortTemplate(templateText, process.env);
  assert.equal(template.source, process.env.GITHUB_SHA);
  assert.match(template.source, /^[a-f0-9]{40}$/);
  assert.equal(template.catalogs.current, null);
  const source = () => {
    assert.equal(
      execFileSync("git", ["rev-parse", "HEAD"], {
        cwd: root,
        encoding: "utf8",
      }).trim(),
      template.source,
    );
    assert.equal(
      execFileSync(
        "git",
        ["status", "--porcelain", "--untracked-files=normal"],
        { cwd: root, encoding: "utf8" },
      ).trim(),
      "",
    );
  };
  source();
  remaining();
  const directory = join(root, "dist/extensions");
  const { include } = JSON.parse(
    await readFile(join(directory, "plan.json"), "utf8"),
  );
  assert.equal(include.length, 1);
  assert.equal(include[0].id, "keepAwake");
  assert.equal(include[0].version, "1.0.1");
  const stage = await publication.publishExtensions({
    directory,
    repository: "pulkitxm/edith",
    target: template.source,
    ref: "refs/heads/main",
    catalogTag: "extension-catalog-v1",
    publicKey: process.env.EXTENSION_CATALOG_PUBLIC_KEY,
    catalogPhase: "stage",
  });
  remaining();
  const identity = publication.stagedExtensionPublication(stage.catalogStage);
  const record = JSON.parse(
    await readFile(join(directory, "keepAwake.json"), "utf8"),
  );
  const lineage = verifiedLineage(
    await readFile(join(directory, "keepAwake.native-evidence.json")),
    process.env.EXTENSION_CATALOG_PUBLIC_KEY,
    record,
  );
  assert.equal(lineage.sourceCommit, template.source);
  assert.equal(String(lineage.runID), process.env.GITHUB_RUN_ID);
  assert.equal(String(lineage.runAttempt), process.env.GITHUB_RUN_ATTEMPT);
  const measurement = join(directory, "production-cohort-current");
  await mkdir(measurement, { mode: 0o700 });
  const context = join(measurement, "context.json");
  await writeFile(
    context,
    JSON.stringify({ template, record, lineage, directory }),
    { mode: 0o600, flag: "wx" },
  );
  const measured = JSON.parse(
    execFileSync(
      "python3",
      [
        "-I",
        "-B",
        join(root, "scripts/hosted-public-release/production-static-inputs.py"),
        "measure-package",
        context,
      ],
      {
        cwd: root,
        env: {
          ...productionReadonlyEnvironment(process.env),
          PUBLISH: "false",
          REBUILD: "",
        },
        timeout: 60000,
        maxBuffer: 65536,
      },
    ).toString(),
  );
  remaining();
  const text = completedProductionCohortRequest(
    template,
    identity,
    record,
    measured,
  );
  const binding = productionCatalogBinding(text, identity);
  const environment = productionObserverEnvironment(process.env, text, binding);
  execFileSync(
    "python3",
    [
      "-I",
      "-B",
      "-c",
      "import importlib.util,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);m.request(sys.stdin.read())",
      join(root, "scripts/hosted-public-release/production-cohort.py"),
    ],
    {
      cwd: root,
      env: environment,
      input: text,
      timeout: 60000,
      maxBuffer: 65536,
    },
  );
  source();
  const observer = await runObserver(text, binding, remaining);
  try {
    await coordinateProductionCatalog(
      observer.channel,
      binding,
      async () => {
        remaining();
        source();
        await publication.promoteStagedExtensionPublication(stage.catalogStage);
        remaining();
        source();
      },
      observer.isActive,
    );
    await observer.joined;
    remaining();
  } catch (error) {
    observer.retire();
    await observer.joined.catch(() => {});
    throw error;
  } finally {
    observer.channel.close();
  }
}
if (import.meta.main) {
  assert.equal(process.argv.length, 2);
  await publishCoordinatedProductionUpdate(
    process.env.PUBLIC_HOST_UPDATE_REQUEST,
  );
}
