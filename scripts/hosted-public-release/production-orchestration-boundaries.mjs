import { mock } from "bun:test";
import assert from "node:assert/strict";
import * as childProcess from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import * as fs from "node:fs";
import * as promises from "node:fs/promises";
import * as os from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";

export async function installOrchestrationBoundaries(stateFile, preload) {
  Object.defineProperty(process, "platform", { value: "darwin" });
  Object.defineProperty(process, "arch", { value: "arm64" });
  const actualFS = { ...promises };
  const actualSpawn = childProcess.spawn;
  const actualState = () => JSON.parse(fs.readFileSync(stateFile));
  const state = actualState();
  if (
    state.variant === "child-retirement" &&
    process.env.GH_TOKEN === undefined
  )
    process.exit(17);
  const repository = state.repository;
  const directory = dirname(repository);
  const application = "/Applications/Edith.app";
  const installation = join(directory, "installed/Edith.app");
  const update = (action) => {
    const value = actualState();
    action(value);
    fs.writeFileSync(stateFile, JSON.stringify(value));
  };
  const event = (value) => update((state) => state.events.push(value));
  const path = (value) => {
    if (typeof value !== "string") return value;
    if (value === application || value.startsWith(`${application}/`))
      return installation + value.slice(application.length);
    assert(
      value === process.execPath ||
        value === directory ||
        value.startsWith(`${directory}/`),
      `Unconfigured filesystem boundary ${value}`,
    );
    return value;
  };
  mock.module("node:fs/promises", () => ({
    ...actualFS,
    lstat: (value, ...args) => actualFS.lstat(path(value), ...args),
    open: (value, ...args) => actualFS.open(path(value), ...args),
    readFile: (value, ...args) => actualFS.readFile(path(value), ...args),
    realpath: async (value, ...args) => {
      const actual = await actualFS.realpath(path(value), ...args);
      return value === application ||
        String(value).startsWith(`${application}/`)
        ? value
        : actual;
    },
  }));
  mock.module("node:os", () => ({
    ...os,
    userInfo: () => ({
      uid: process.getuid(),
      gid: process.getgid(),
      username: "synthetic",
      homedir: state.home,
      shell: "/bin/sh",
    }),
  }));
  globalThis.fetch = async (url, options = {}) => {
    const value = actualState();
    const parsed = new URL(url);
    if (parsed.origin === "https://api.github.com") {
      assert.equal(
        options.headers.Authorization,
        "Bearer synthetic-readonly-token",
      );
      const route =
        parsed.pathname.replace(/^\/repos\/pulkitxm\/edith/, "") +
        parsed.search;
      if (route.startsWith("/releases/tags/")) {
        const release = value.releases.find(
          ({ tag_name }) =>
            tag_name === decodeURIComponent(route.split("/").at(-1)),
        );
        assert(release, route);
        return new Response(JSON.stringify(release));
      }
      assert(value.api[route], `Unknown synthetic API route ${route}`);
      return new Response(JSON.stringify(value.api[route]));
    }
    assert.equal(parsed.origin, "https://github.com");
    const asset = value.releases
      .flatMap(({ assets }) => assets)
      .find(({ browser_download_url }) => browser_download_url === parsed.href);
    assert(asset, `Unknown synthetic artifact ${parsed.href}`);
    return new Response(Buffer.from(value.bytes[asset.id], "base64"));
  };
  mock.module("node:child_process", () => ({
    ...childProcess,
    spawn: (file, args, options) => {
      if (file === "gh" && args[0] === "api")
        return actualSpawn(file, args, options);
      assert.equal(file, process.execPath);
      assert.deepEqual(args, [
        join(
          repository,
          "scripts/hosted-public-release/production-coordinated-runner.mjs",
        ),
      ]);
      assert(
        !options.env.NODE_OPTIONS &&
          !options.env.GH_TOKEN &&
          !options.env.EXTENSION_CATALOG_PRIVATE_KEY,
      );
      assert.deepEqual(options.stdio, [
        "ignore",
        "inherit",
        "inherit",
        "pipe",
        "pipe",
      ]);
      event({ kind: "observer-starting" });
      const child = actualSpawn(file, ["--preload", preload, ...args], options);
      child.once("spawn", () =>
        event({ kind: "observer-started", pid: child.pid }),
      );
      child.once("close", (code, signal) =>
        event({ kind: "observer-closed", code, signal }),
      );
      return child;
    },
  }));
  const digest = (value) => createHash("sha256").update(value).digest("hex");
  const history = new Map();
  let owners = [];
  let nextPID = process.pid + 1000000;
  let generation = "previous";
  let packageVersion = "1.0.0";
  let enabled = false;
  let assertions = 0;
  let surface = "home";
  const layout = {
    "com.pulkit.edith.shared:surfaceGrid.home": digest("empty home"),
    "com.pulkit.edith.shared:surfaceGrid.notch": digest("empty notch"),
    "com.pulkit.edith.shared:surfaceEditorTarget": digest("notch"),
    "com.pulkit.edith.shared:surfaceEditorWidget": digest("keepAwake"),
  };
  let scope;
  const roleOwner = (role) => {
    const matches = scope.roles.filter(
      (row) =>
        row.role === role &&
        (role === "host" || role === "engine"
          ? row.codeHash === (generation === "previous" ? "a" : "b").repeat(40)
          : role === "managedUI"
            ? row.executable.includes(`/${packageVersion}/`)
            : true),
    );
    assert(matches.length);
    const row = {
      role,
      pid: nextPID++,
      generation: `${nextPID}:1`,
      executable: matches[0].executable,
      codeHash: matches[0].codeHash,
      running: true,
    };
    owners.push(row);
    history.set(`${row.role}:${row.pid}:${row.generation}`, row);
    return row;
  };
  const retire = (roles) => {
    for (const row of owners.filter(({ role }) => roles.includes(role)))
      row.running = false;
    owners = owners.filter(({ running }) => running);
  };
  const rows = () => owners.map((row) => ({ ...row }));
  const info = () => ({
    id: "keepAwake",
    title: "Keep Awake",
    installed: true,
    removalPending: false,
    disablePending: false,
    compatible: true,
    enabled,
    running: enabled,
    processIdentifier: enabled
      ? owners.find(({ role }) => role === "engine").pid
      : null,
    state: enabled ? "running" : "installed",
    version: packageVersion,
    availableVersion: "1.0.1",
    updateAvailable: packageVersion !== "1.0.1",
    offline: false,
  });
  const writeBundle = async (bundle, which) => {
    const executable = join(bundle, "Contents/MacOS/Edith");
    await actualFS.mkdir(dirname(executable), { recursive: true, mode: 0o700 });
    await actualFS.writeFile(
      executable,
      Buffer.from(actualState()[which].executable, "base64"),
      { mode: 0o700 },
    );
  };
  const native = async (file, args, options) => {
    assert(
      Number.isInteger(options.timeoutMs) &&
        options.timeoutMs > 0 &&
        options.timeoutMs <= 180000,
    );
    event({
      kind: "native-boundary",
      operation:
        file === "xcrun"
          ? "compile-synthetic-probe"
          : file.startsWith(directory)
            ? "synthetic-probe"
            : file,
    });
    if (file === "xcrun") {
      assert.equal(args[0], "swiftc");
      const output = args[args.indexOf("-o") + 1];
      assert(
        output.startsWith(`${repository}/local/public-host-cohort/observer-`),
      );
      await actualFS.writeFile(
        output,
        "synthetic never-executed probe artifact",
        { mode: 0o700, flag: "wx" },
      );
      return;
    }
    if (file === "/usr/bin/hdiutil") {
      if (args[0] === "detach") {
        assert(args[1].startsWith(`${repository}/local/`));
        return;
      }
      assert.equal(args[0], "attach");
      const mount = args[args.indexOf("-mountpoint") + 1];
      assert(mount.startsWith(`${repository}/local/`));
      await writeBundle(join(mount, "Edith.app"), "previous");
      return;
    }
    if (file === "/usr/bin/ditto") {
      assert.equal(args[1], application);
      await actualFS.cp(path(args[0]), installation, { recursive: true });
      return;
    }
    if (file === "/usr/bin/open") {
      assert.deepEqual(args, ["-a", application]);
      roleOwner("host");
      return;
    }
    const response = async (value) => {
      assert(Number.isInteger(options.stdio[1]));
      fs.writeFileSync(options.stdio[1], JSON.stringify(value));
    };
    if (file === `${application}/Contents/MacOS/Edith`) {
      assert.equal(args[0], "extensions");
      assert.equal(args[2], "keepAwake");
      assert.equal(args[3], "--json");
      const operation = args[1];
      if (operation === "enable") {
        enabled = true;
        roleOwner("engine");
        roleOwner("managedUI");
      } else if (operation === "update") {
        retire(["engine", "managedUI"]);
        packageVersion = "1.0.1";
        roleOwner("engine");
        roleOwner("managedUI");
      } else assert(["install", "info"].includes(operation));
      await response(info());
      return;
    }
    assert(
      file.startsWith(`${repository}/local/public-host-cohort/observer-`) &&
        file.endsWith("/ProductionHostProbe"),
      `Unknown synthetic native launch ${file}`,
    );
    if (args[0] === "producer") {
      await response({
        pid: process.pid,
        generation: "1:1",
        executable: await actualFS.realpath(process.execPath),
        codeHash: "c".repeat(40),
      });
      return;
    }
    assert.equal(args.length, 0);
    const request = JSON.parse(fs.readFileSync(options.stdio[0], "utf8"));
    const source = await actualFS.readFile(
      join(dirname(file), "ProductionHostProbe.swift"),
      "utf8",
    );
    const issuer = source.match(
      /static let issuer = Data\(base64Encoded: "([A-Za-z0-9+/=]+)"\)/,
    )[1];
    const key = createPublicKey({
      format: "jwk",
      key: {
        kty: "OKP",
        crv: "Ed25519",
        x: Buffer.from(issuer, "base64").toString("base64url"),
      },
    });
    const payload = Buffer.from(request.scope.payload, "base64");
    assert(
      verify(
        null,
        payload,
        key,
        Buffer.from(request.scope.signature, "base64"),
      ),
    );
    scope = JSON.parse(payload);
    assert.equal(scope.sourceCommit, state.source);
    assert.equal(scope.producerPID, process.pid);
    assert.equal(scope.producerGeneration, "1:1");
    assert.equal(
      scope.producerExecutable,
      await actualFS.realpath(process.execPath),
    );
    assert.equal(scope.producerCodeHash, "c".repeat(40));
    assert.equal(scope.uid, process.getuid());
    assert.equal(scope.accountHome, state.home);
    if (request.operation === "snapshot") await response(rows());
    else if (request.operation === "observe")
      await response(
        request.observed.map((row) => {
          const actual = history.get(
            `${row.role}:${row.pid}:${row.generation}`,
          );
          assert(actual);
          assert.deepEqual({ ...actual, running: true }, row);
          return { ...actual };
        }),
      );
    else if (request.operation === "state") {
      if (generation === "current")
        event({ kind: "restored-layout-read", layout: { ...layout } });
      await response(layout);
    } else if (request.operation === "assertions")
      await response({ engineAssertions: assertions });
    else if (request.operation === "quit") {
      retire(owners.map(({ role }) => role));
      event({ kind: "owned-quit" });
      await response({});
    } else {
      const action = request.operation;
      assert(
        [
          "finishWelcome",
          "goHome",
          "widgetEditor",
          "home",
          "notch",
          "addKeep",
          "pressKeep",
          "openEdithMenu",
          "checkUpdates",
          "installUpdate",
          "installRelaunch",
        ].includes(action),
      );
      if (state.variant === "primary-native-failure" && action === "pressKeep")
        throw new Error("Synthetic native action failure");
      const before = rows();
      const host = before.find(({ role }) => role === "host");
      assert(host);
      const peer = ["installUpdate", "installRelaunch"].includes(action)
        ? before.find(({ role }) => role === "sparkleUpdater")
        : host;
      assert(peer);
      if (["home", "notch"].includes(action)) surface = action;
      if (action === "addKeep")
        layout[`com.pulkit.edith.shared:surfaceGrid.${surface}`] = digest(
          `saved ${surface} keepAwake`,
        );
      if (action === "pressKeep") assertions = 1 - assertions;
      if (action === "checkUpdates") roleOwner("sparkleUpdater");
      if (action === "installRelaunch") {
        retire(["host", "engine", "managedUI", "sparkleUpdater"]);
        generation = "current";
        await writeBundle(installation, generation);
        roleOwner("host");
        roleOwner("engine");
        roleOwner("managedUI");
        event({ kind: "different-host-restored" });
      }
      await response({
        performedAction: action,
        postActionOwners: [peer, host].map((row) => ({
          ...history.get(`${row.role}:${row.pid}:${row.generation}`),
        })),
      });
    }
  };
  mock.module(
    pathToFileURL(
      join(repository, "scripts/hosted-original-shell/owned-command.mjs"),
    ).href,
    () => ({ runOwnedJourneyCommand: native }),
  );
  return { repository };
}
