import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  productionCatalogBinding,
  productionCatalogChannel,
  productionCatalogMessage,
  productionObserverEnvironment,
  productionReadonlyEnvironment,
  validateProductionCatalogMessage,
} from "./production-catalog-channel.mjs";

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
export function completedProductionCohortRequest(template, identity, record) {
  assert.equal(template.catalogs.current, null);
  assert.equal(template.source, identity.source);
  assert.equal(template.application, "/Applications/Edith.app");
  assert.equal(record.id, "keepAwake");
  assert.equal(record.version, "1.0.1");
  assert.equal(template.packages.current.version, record.version);
  assert.equal(template.packages.current.archiveSHA256, record.sha256);
  assert.equal(
    template.packages.current.sourceFingerprint,
    record.sourceFingerprint,
  );
  for (const key of ["revision", "sha256", "bytes"])
    assert.equal(template.catalogs.previous[key], identity.previous[key]);
  const request = {
    ...template,
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
async function runObserver(text, binding) {
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
  const timeout = setTimeout(
    () => {
      timedOut = true;
      retire();
    },
    180 * 60 * 1000,
  );
  return {
    channel,
    joined,
    isActive: () =>
      !completed &&
      !timedOut &&
      child.exitCode === null &&
      child.signalCode === null,
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
      "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('cohort',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);v=json.loads(sys.stdin.read(),object_pairs_hook=m.unique_object);m.exact(v,['schema','source','application','hosts','packages','catalogs']);m.require(v['schema']==1 and type(v['schema']) is int,'Invalid schema');m.source(v['source']);m.require(v['application']==m.APPLICATION,'Noncanonical application');m.exact(v['catalogs'],['previous','current']);m.require(v['catalogs']['current'] is None,'Current catalog must be measured by staging');print(json.dumps(v))",
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
  const directory = join(root, "dist/extensions");
  const { include } = JSON.parse(
    await readFile(join(directory, "plan.json"), "utf8"),
  );
  assert.equal(include.length, 1);
  assert.equal(include[0].id, "keepAwake");
  assert.equal(include[0].version, "1.0.1");
  const record = JSON.parse(
    await readFile(join(directory, "keepAwake.json"), "utf8"),
  );
  assert.equal(template.packages.current.archiveSHA256, record.sha256);
  const stage = await publication.publishExtensions({
    directory,
    repository: "pulkitxm/edith",
    target: template.source,
    ref: "refs/heads/main",
    catalogTag: "extension-catalog-v1",
    publicKey: process.env.EXTENSION_CATALOG_PUBLIC_KEY,
    catalogPhase: "stage",
  });
  const identity = publication.stagedExtensionPublication(stage.catalogStage);
  const text = completedProductionCohortRequest(template, identity, record);
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
  const observer = await runObserver(text, binding);
  try {
    await coordinateProductionCatalog(
      observer.channel,
      binding,
      async () => {
        source();
        await publication.promoteStagedExtensionPublication(stage.catalogStage);
        source();
      },
      observer.isActive,
    );
    await observer.joined;
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
