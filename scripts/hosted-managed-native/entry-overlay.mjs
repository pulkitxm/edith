import assert from "node:assert/strict";

export function hostedProbeEntry(entry) {
  const anchor =
    '        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"';
  assert.equal(
    entry.split(anchor).length,
    2,
    "Ambiguous host CLI dispatch anchor",
  );
  return entry.replace(
    anchor,
    `        #if EDITH_CLI_FIXTURE
        if ProbeLaunch.requested(arguments) {
            do {
                try HostedManagedApprovalProbe.dispatch(arguments: arguments)
            } catch {
                FileHandle.standardError.write(Data("Hosted probe admission failed: \\(error)\\n".utf8))
                exit(1)
            }
            return
        }
        #endif
${anchor}`,
  );
}
