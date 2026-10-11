import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";

const sourcePaths = [
  "Extensions/fixtureSupport/WorkerFixtureJSON.swift",
  "Tests/HostedFunctionalActions/Sources/FunctionalActionContract/HostedFunctionalActionContext.swift",
  "Packages/ExtensionSupport/Sources/EdithExtensionSupport/ExtensionEngine.swift",
  "Tests/HostedFunctionalActions/RuntimeSources/HostedFunctionalActionTransport.swift",
  "Tests/HostedFunctionalActions/TransportContractSources/Shim.swift",
  "Tests/HostedFunctionalActions/TransportContractSources/Probe.swift",
];

export async function runFunctionalTransportContract(root, output) {
  assert(
    output.startsWith("/") &&
      output.includes("/functional-transport-contract-"),
  );
  assert.equal(resolve(output), output);
  await mkdir(output, { mode: 0o700 });
  const sources = await Promise.all(
    sourcePaths.map((path) => readFile(join(root, path), "utf8")),
  );
  const copied = [];
  for (const [index, source] of sources.entries()) {
    const path = join(output, sourcePaths[index].split("/").at(-1));
    const text = source.replace(
      /^import (?:EdithExtensionSupport|FunctionalActionContract|WorkerFixtureSupport)\n/gm,
      "",
    );
    await writeFile(path, text, { flag: "wx", mode: 0o600 });
    copied.push(path);
  }
  const run = (command, args) =>
    new Promise((resolve, reject) => {
      const child = spawn(command, args, {
        cwd: output,
        env: process.env,
        stdio: ["ignore", "pipe", "pipe"],
      });
      const chunks = [];
      let size = 0;
      const collect = (bytes) => {
        size += bytes.length;
        if (size > 131072) child.kill("SIGTERM");
        else chunks.push(bytes);
      };
      child.stdout.on("data", collect);
      child.stderr.on("data", collect);
      child.on("error", reject);
      child.on("close", (code) => {
        if (code === 0 && size <= 131072)
          resolve(Buffer.concat(chunks).toString("utf8"));
        else
          reject(
            new Error(
              `Synthetic transport contract failed: ${Buffer.concat(chunks).toString("utf8")}`,
            ),
          );
      });
      const timeout = setTimeout(() => child.kill("SIGTERM"), 60000);
      child.on("close", () => clearTimeout(timeout));
    });
  const binary = join(output, "transport-contract");
  await run("xcrun", [
    "swiftc",
    "-j",
    "1",
    "-swift-version",
    "6",
    "-parse-as-library",
    ...copied,
    "-o",
    binary,
  ]);
  const log = await run(binary, []);
  for (const [index, path] of sourcePaths.entries())
    assert.equal(await readFile(join(root, path), "utf8"), sources[index]);
  return Object.freeze({
    scope: "Foundation transport control flow with inert endpoint and client",
    productExecution: false,
    log,
    sourcePins: sourcePaths.map((path, index) => ({
      path,
      sha256: createHash("sha256").update(sources[index]).digest("hex"),
    })),
  });
}
