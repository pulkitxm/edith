export const lifecycleHarnessStages = Object.freeze([
  "fixtureOwnerBegin",
  "fixtureOwnerComplete",
  "fixtureCopyBegin",
  "fixtureCopyComplete",
  "fixtureSignBegin",
  "fixtureSignComplete",
  "hostIdentityBegin",
  "hostIdentityComplete",
  "fixtureHomeBegin",
  "fixtureHomeComplete",
  "packageStoreBegin",
  "packageStoreComplete",
  "ownerDefaultsBegin",
  "ownerDefaultsComplete",
  "peerEndpointBegin",
  "peerEndpointComplete",
  "sessionsBegin",
  "sessionsComplete",
  "surfacesBegin",
  "surfacesComplete",
  "packageInstallBegin",
  "packageInstallComplete",
]);
const stages = new Set(lifecycleHarnessStages);
const signals = new Set([
  "SIGABRT",
  "SIGBUS",
  "SIGILL",
  "SIGKILL",
  "SIGSEGV",
  "SIGTERM",
  "SIGTRAP",
]);

export function lifecycleHarnessLastStage(stderr, pid) {
  if (!Number.isInteger(pid) || pid <= 1 || pid > 2147483647) return null;
  if (Buffer.isBuffer(stderr)) {
    if (stderr.length > 65536) return null;
    const text = stderr.toString("utf8");
    if (!stderr.equals(Buffer.from(text))) return null;
    stderr = text;
  }
  if (typeof stderr !== "string" || Buffer.byteLength(stderr) > 65536)
    return null;
  let last = null;
  let count = 0;
  for (const line of stderr.split("\n")) {
    if (!line.includes("lifecycleHarnessStage")) continue;
    if (Buffer.byteLength(line) > 256 || ++count > 128) return null;
    try {
      const row = JSON.parse(line);
      if (
        !row ||
        Object.getPrototypeOf(row) !== Object.prototype ||
        Object.keys(row).sort().join(",") !==
          "lifecycleHarnessStage,name,pid" ||
        row.name !== "HostLifecycleHarness" ||
        row.pid !== pid ||
        JSON.stringify(row) !== line ||
        !stages.has(row.lifecycleHarnessStage)
      )
        return null;
      last = row.lifecycleHarnessStage;
    } catch {
      return null;
    }
  }
  return last;
}

export function lifecycleHarnessSignalFailure(error, source) {
  if (
    !error ||
    !signals.has(error.signal) ||
    !Number.isInteger(error.pid) ||
    error.pid <= 1 ||
    error.pid > 2147483647
  )
    return null;
  return Object.freeze({
    signal: error.signal,
    pid: error.pid,
    source:
      typeof source === "string" && /^[a-f0-9]{40}$/.test(source)
        ? source
        : null,
    stage: lifecycleHarnessLastStage(error.stderr, error.pid),
  });
}
