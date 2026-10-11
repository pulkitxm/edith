import assert from "node:assert/strict";

function replaceExact(source, before, after) {
  assert.equal(
    source.split(before).length,
    2,
    "Changed or ambiguous Sparkle fixture source anchor",
  );
  return source.replace(before, after);
}

export function sparkleEntryOverlay(
  source,
  { sourceCommit, issuerPublicKey, signingRequirement },
) {
  assert(
    typeof sourceCommit === "string" &&
      sourceCommit.length === 40 &&
      /^[a-f0-9]{40}$/.test(sourceCommit),
  );
  const key = Buffer.from(issuerPublicKey, "base64");
  assert.equal(key.length, 32);
  assert.equal(key.toString("base64"), issuerPublicKey);
  assert(signingRequirement.length > 0 && signingRequirement.length <= 1024);
  assert(
    [...signingRequirement].every(
      (value) => value.charCodeAt(0) >= 32 && value.charCodeAt(0) < 127,
    ),
  );
  const before =
    "        guard arguments.isEmpty else { HostCommandCLI.main(arguments: arguments) }\n        HostApplication.main()";
  const after = `        guard arguments.isEmpty else { HostCommandCLI.main(arguments: arguments) }
        do {
            try HostSparkleBootstrap.restore(
                sourceCommit: ${JSON.stringify(sourceCommit)},
                issuerPublicKey: Data(base64Encoded: ${JSON.stringify(issuerPublicKey)})!,
                signingRequirement: ${JSON.stringify(signingRequirement)})
        } catch { exit(1) }
        HostApplication.main()`;
  let result = replaceExact(
    source,
    before,
    after.replace(
      "guard arguments.isEmpty else { HostCommandCLI.main(arguments: arguments) }",
      "guard arguments.isEmpty else { exit(1) }",
    ),
  );
  result = replaceExact(
    result,
    '        let arguments = Array(CommandLine.arguments.dropFirst())\n        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"',
    `        let arguments = Array(CommandLine.arguments.dropFirst())
        guard getenv("EDITH_CLI") == nil,
            !arguments.isEmpty || getenv("EDITH_EXTENSION_WORKER") == nil,
            arguments.isEmpty || arguments[0].hasPrefix("--extension-")
                || arguments[0].hasPrefix("--contained-extension-")
        else { exit(1) }
        if ProcessInfo.processInfo.environment["EDITH_CLI"] == "1"`,
  );
  return result;
}

export function sparkleUpdaterOverlay(source) {
  assert.equal(
    source.split('Bundle.main.bundleIdentifier == "com.pulkit.edith"').length,
    2,
  );
  assert.equal(
    source.split('Bundle.main.bundleURL.path == "/Applications/Edith.app"')
      .length,
    2,
  );
  let result = replaceExact(
    source,
    "        guard startingUpdater, production else { return }",
    "        guard startingUpdater, production || HostSparkleBootstrap.admitted else { return }",
  );
  result = replaceExact(
    result,
    "    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {",
    `    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        HostSparkleBootstrap.record("downloaded")
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        HostSparkleBootstrap.record("extracted")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        HostSparkleBootstrap.record("installing")
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        HostSparkleBootstrap.record("relaunching")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {`,
  );
  result = replaceExact(
    result,
    "        if let error {\n            let code = (error as NSError).code",
    "        if let error {\n            if HostSparkleBootstrap.admitted { HostSparkleBootstrap.recordRejection(error) }\n            let code = (error as NSError).code",
  );
  return result;
}
