import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash, generateKeyPairSync, sign } from "node:crypto";
import { existsSync } from "node:fs";
import {
  copyFile,
  cp,
  mkdir,
  mkdtemp,
  readFile,
  rm,
  writeFile,
} from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import {
  buildExtensionSupport,
  rewriteSupportImports,
} from "./build-extension-support.mjs";

const fixture = await mkdtemp(join(tmpdir(), "edith-cli-fixture-"));
const app = join(fixture, "Edith.app");
const identifier = `com.pulkit.edith.tests.cli-${crypto.randomUUID()}`;
let host;
let identityRoot;
const run = (command, args, options = {}) =>
  execFileSync(command, args, { stdio: "pipe", ...options });
const ed = join(app, "Contents/MacOS/ed");
async function command(args, expected = 0, input) {
  const result = await new Promise((resolveResult, reject) => {
    const child = spawn(ed, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      reject(new Error(`Command hung: ${args.join(" ")}`));
    }, 45000);
    child.stdout.on("data", (data) => {
      stdout += data;
    });
    child.stderr.on("data", (data) => {
      stderr += data;
    });
    child.on("error", reject);
    child.on("exit", (code) => {
      clearTimeout(timer);
      resolveResult({ code, stdout, stderr });
    });
    child.stdin.end(input);
  });
  assert.equal(result.code, expected, JSON.stringify({ args, ...result }));
  if (expected !== 0) {
    assert.equal(result.stdout, "");
    assert.equal(JSON.parse(result.stderr).exitCode, expected);
    return JSON.parse(result.stderr);
  }
  assert.equal(result.stderr, "");
  return args.includes("--help") || args.includes("--raw")
    ? result.stdout
    : JSON.parse(result.stdout);
}
async function until(predicate) {
  const deadline = Date.now() + 10000;
  while (!(await predicate())) {
    assert(Date.now() < deadline, "Fixture state timed out");
    await sleep(25);
  }
}
function children() {
  return run("ps", ["-axo", "pid=,ppid=,comm="], { encoding: "utf8" })
    .split("\n")
    .filter((line) => Number(line.trim().split(/\s+/)[1]) === host.pid);
}
try {
  await cp(resolve("local/minimal-host/Edith.app"), app, { recursive: true });
  await copyFile(
    "Resources/ed-launcher",
    join(app, "Contents/Resources/ed-launcher"),
  );
  run("chmod", ["755", join(app, "Contents/Resources/ed-launcher")]);
  run("ln", ["-s", "../Resources/ed-launcher", ed]);
  run("python3", [
    "-c",
    "import plistlib,sys; p=sys.argv[1]; d=plistlib.load(open(p,'rb')); d['CFBundleIdentifier']=sys.argv[2]; plistlib.dump(d,open(p,'wb'))",
    join(app, "Contents/Info.plist"),
    identifier,
  ]);
  run("codesign", ["--force", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  assert.match(await command(["--help"]), /ed extensions ls/);
  assert.match((await command(["--version"])).version, /^0\.\d+\.\d+$/);
  await command(["unrecognized"], 2);
  await command(["extensions", "ls"], 3);
  await command(["--extension-worker"], 2);
  const developer =
    process.env.DEVELOPER_DIR ?? "/Applications/Xcode.app/Contents/Developer";
  const build = [
    "build",
    "--package-path",
    "Packages/EdithHost",
    "--build-system",
    "native",
    "--configuration",
    "release",
    "--jobs",
    "1",
    "--product",
    "EdithHost",
    "-Xswiftc",
    "-Osize",
    "-Xswiftc",
    "-D",
    "-Xswiftc",
    "EDITH_CLI_FIXTURE",
    "-Xswiftc",
    "-plugin-path",
    "-Xswiftc",
    `${developer}/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins`,
  ];
  execFileSync("swift", build, { stdio: "inherit" });
  const productsPath = run(
    "swift",
    [
      "build",
      "--package-path",
      "Packages/EdithHost",
      "--build-system",
      "native",
      "--configuration",
      "release",
      "--show-bin-path",
    ],
    { encoding: "utf8" },
  ).trim();
  const binary = join(app, "Contents/MacOS/Edith");
  await copyFile(join(productsPath, "EdithHost"), binary);
  const links = run("otool", ["-L", binary], { encoding: "utf8" });
  for (const line of links.split("\n").slice(1)) {
    const dependency = line.trim().split(" ")[0];
    if (dependency.endsWith("/Sparkle.framework/Versions/B/Sparkle"))
      run("install_name_tool", [
        "-change",
        dependency,
        "@rpath/Sparkle.framework/Sparkle",
        binary,
      ]);
  }
  run("install_name_tool", [
    "-add_rpath",
    "@executable_path/../Frameworks",
    binary,
  ]);
  run("strip", ["-rSTx", binary]);
  run("codesign", ["--force", "--sign", "-", app]);
  run("codesign", ["--verify", "--deep", "--strict", app]);
  const products = buildExtensionSupport(
    process.cwd(),
    "EdithExtensionArchive",
    "CLIFixture_helper",
  );
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  await writeFile(
    join(fixture, "public.key"),
    publicKey.export({ type: "spki", format: "der" }).subarray(-32),
  );
  const packages = [];
  for (const version of ["1.0.0", "1.1.0"]) {
    const payload = join(fixture, version, "keepAwake");
    const bundle = join(payload, "helper.bundle");
    const contents = join(bundle, "Contents");
    await mkdir(join(contents, "MacOS"), { recursive: true });
    const source = join(fixture, `Runtime-${version}.swift`);
    await writeFile(
      source,
      rewriteSupportImports(
        (
          await readFile(
            "Packages/EdithHost/Tests/CLIFixture/Runtime.swift",
            "utf8",
          )
        ).replace("VERSION", version),
        products.modules,
      ),
    );
    run("xcrun", [
      "swiftc",
      "-emit-library",
      "-parse-as-library",
      "-Osize",
      "-swift-version",
      "5",
      "-module-name",
      "EdithCLIFixture",
      "-target",
      "arm64-apple-macos14.0",
      source,
      "-I",
      join(products.products, "Modules"),
      "-L",
      products.products,
      `-l${products.product}`,
      "-Xlinker",
      "-dead_strip",
      "-Xlinker",
      "-install_name",
      "-Xlinker",
      "@rpath/EdithCLIFixture",
      "-o",
      join(contents, "MacOS/Runtime"),
    ]);
    const info = {
      CFBundleIdentifier: "com.pulkit.edith.extensions.keepAwake.helper",
      CFBundleExecutable: "Runtime",
      CFBundlePackageType: "BNDL",
      CFBundleShortVersionString: version,
      EdithHostABI: "edith-host-1",
    };
    run("python3", [
      "-c",
      "import json,plistlib,sys; plistlib.dump(json.loads(sys.argv[1]),open(sys.argv[2],'wb'))",
      JSON.stringify(info),
      join(contents, "Info.plist"),
    ]);
    run("codesign", ["--force", "--sign", "-", bundle]);
    await writeFile(
      join(payload, "package.json"),
      JSON.stringify({
        id: "keepAwake",
        version,
        hostABI: "edith-host-1",
        architecture: "arm64",
        dependencies: [],
      }),
    );
    const archive = join(fixture, `${version}.zip`);
    const installedBytes = Number(
      run(
        "python3",
        [
          "-c",
          "import pathlib,sys,zipfile; r=pathlib.Path(sys.argv[1]); fs=sorted(p for p in r.rglob('*') if p.is_file()); z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED); [z.write(p,p.relative_to(r.parent)) for p in fs]; z.close(); print(sum(p.stat().st_size for p in fs))",
          payload,
          archive,
        ],
        { encoding: "utf8" },
      ),
    );
    const bytes = await readFile(archive);
    packages.push({
      id: "keepAwake",
      version,
      hostABI: "edith-host-1",
      architecture: "arm64",
      minimumSystemVersion: 14,
      dependencies: [],
      downloadURL: `https://github.com/pulkitxm/edith/releases/download/${version}/keepAwake.zip`,
      sha256: createHash("sha256").update(bytes).digest("hex"),
      downloadBytes: bytes.length,
      installedBytes,
    });
  }
  async function catalog(revision, count) {
    const payload = Buffer.from(
      JSON.stringify({
        schemaVersion: 1,
        revision,
        packages: packages.slice(0, count),
      }),
    );
    await writeFile(
      join(fixture, "catalog.json"),
      JSON.stringify({
        payload: payload.toString("base64"),
        signature: sign(null, payload, privateKey).toString("base64"),
      }),
    );
  }
  await catalog(1, 1);
  host = spawn(join(app, "Contents/MacOS/Edith"), ["--cli-fixture", fixture], {
    stdio: ["ignore", "ignore", "pipe"],
  });
  let hostError = "";
  host.stderr.on("data", (data) => {
    hostError += data;
  });
  await until(() => {
    assert(host.exitCode === null, hostError);
    return existsSync(join(fixture, "ready.json"));
  });
  const ready = JSON.parse(await readFile(join(fixture, "ready.json"), "utf8"));
  identityRoot = ready.root;

  assert.equal(ready.pid, host.pid);
  assert.equal(children().length, 0);
  const list = await command(["extensions", "ls"]);
  assert(list.length >= 35);
  await command(["extensions", "info", "missing"], 1);
  let info = await command(["extensions", "install", "keepAwake"]);
  assert.equal(info.version, "1.0.0");
  assert.equal(info.running, false);
  await command(["invoke", "keepAwake", "echo"], 1);
  assert.equal(children().length, 0);
  info = await command(["extensions", "enable", "keepAwake"]);
  assert.equal(info.running, true);
  assert.equal(children().length, 1);
  assert.deepEqual(
    await command([
      "invoke",
      "keepAwake",
      "echo",
      "--json",
      '{"value":"synthetic"}',
    ]),
    { value: "synthetic" },
  );
  assert.deepEqual(
    await command(
      ["invoke", "keepAwake", "echo", "--json", "-"],
      0,
      '{"stdin":true}',
    ),
    { stdin: true },
  );
  await command(["invoke", "keepAwake", "missing"], 1);
  const archive = run(
    "python3",
    [
      "-c",
      "import base64,io,zipfile; b=io.BytesIO(); z=zipfile.ZipFile(b,'w'); z.writestr('fixture.txt','synthetic archive'); z.close(); print(base64.b64encode(b.getvalue()).decode())",
    ],
    { encoding: "utf8" },
  ).trim();
  assert.deepEqual(
    await command([
      "invoke",
      "keepAwake",
      "archive",
      "--json",
      JSON.stringify({ archive }),
    ]),
    { text: "synthetic archive" },
  );
  for (const value of ["", "synthetic 🌤", "first\nsecond\n"]) {
    assert.equal(
      await command([
        "invoke",
        "keepAwake",
        "echo",
        "--json",
        JSON.stringify(value),
        "--raw",
      ]),
      `${value}\n`,
    );
  }
  await command(["invoke", "keepAwake", "echo", "--raw"], 1);
  const marker = join(identityRoot, "Data/keepAwake/wait.ready");
  await command(["invoke", "keepAwake", "wait", "--timeout", "1"], 4);
  await until(() => !existsSync(marker));
  const cancelled = spawn(ed, ["invoke", "keepAwake", "wait"], {
    stdio: "ignore",
  });
  await until(() => existsSync(marker));
  cancelled.kill("SIGTERM");
  await until(() => !existsSync(marker));
  const blocking = command(["invoke", "keepAwake", "blockUI"]);
  await until(() => existsSync(join(identityRoot, "Data/keepAwake/ui.ready")));
  const start = Date.now();
  await command(["extensions", "ls"]);
  assert(Date.now() - start < 900, "Worker UI blocked host control");
  await blocking;
  await catalog(2, 2);
  info = await command(["extensions", "update", "keepAwake"]);
  assert.equal(info.version, "1.1.0");
  assert.equal(info.running, true);
  assert.deepEqual(await command(["invoke", "keepAwake", "echo"]), {});
  run("python3", [
    "-c",
    "import json,socket,struct,sys; s=socket.socket(socket.AF_UNIX); s.settimeout(3); s.connect(sys.argv[1]); p=json.dumps({'action':'remove','id':'keepAwake','payload':'e30=','timeout':30,'pid':int(sys.argv[2]),'executable':sys.argv[3]}).encode(); s.sendall(struct.pack('>I',len(p))+p); h=s.recv(4); d=s.recv(struct.unpack('>I',h)[0]) if len(h)==4 else b''; assert not d or json.loads(d).get('error')",
    ready.socket,
    String(host.pid),
    join(app, "Contents/MacOS/Edith"),
  ]);
  assert.equal(
    (await command(["extensions", "info", "keepAwake"])).running,
    true,
  );
  await command(
    ["invoke", "keepAwake", "echo", "--json", "-"],
    2,
    `"${"x".repeat(512 * 1024)}"`,
  );
  await rm(join(fixture, "catalog.json"));
  await rm(join(fixture, "1.1.0.zip"));
  await command(["extensions", "install", "colorPicker"], 1);
  info = await command(["extensions", "info", "keepAwake"]);
  assert.equal(info.running, true);
  assert.equal(info.offline, true);
  info = await command(["extensions", "disable", "keepAwake"]);
  assert.equal(info.running, false);
  assert.equal(info.enabled, false);
  await until(() => children().length === 0);
  await command(["invoke", "keepAwake", "echo"], 1);
  info = await command(["extensions", "remove", "keepAwake"]);
  assert.equal(info.installed, false);
  assert.equal(children().length, 0);
  await writeFile(join(fixture, "stop"), "stop");
  await until(() => host.exitCode !== null);
  assert.equal(host.exitCode, 0);
  assert(
    !hostError.includes("is implemented in both"),
    "Duplicate runtime classes loaded",
  );
  await until(() => !existsSync(ready.socket));
  await command(["extensions", "ls"], 3);
  process.stdout.write(
    `${JSON.stringify({ publicLauncher: true, sameSignedExecutable: true, install: "1.0.0", update: "1.1.0", invokeJSONAndStdin: true, scopedArchiveDecoder: true, duplicateRuntimeClasses: false, timeoutAndDisconnectCancellation: true, responsiveHost: true, forgedCallerRejected: true, boundedRequests: true, offlineError: true, disabledWorkers: 0, removedPayload: true, socketCleanup: true })}\n`,
  );
} finally {
  if (host && host.exitCode === null) {
    await writeFile(join(fixture, "stop"), "stop");
    await sleep(500);
    if (host.exitCode === null) host.kill("SIGTERM");
  }
  if (identityRoot) await rm(identityRoot, { recursive: true, force: true });
  await rm(fixture, { recursive: true, force: true });
}
