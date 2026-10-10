import assert from "node:assert/strict";

function replaceExact(source, before, after) {
  assert.equal(
    source.split(before).length,
    2,
    "Managed fixture source anchor changed",
  );
  return source.replace(before, after);
}

export function managedFixtureOverlay(source) {
  let result = replaceExact(
    source,
    '        guard Bundle.main.bundleIdentifier?.hasPrefix("com.pulkit.edith.tests.remote-") == true',
    '        guard let identifier = Bundle.main.bundleIdentifier,\n            identifier.hasPrefix("com.pulkit.edith.tests.remote-")\n                || identifier.hasPrefix("com.pulkit.edith.tests.worker-")',
  );
  result = replaceExact(
    result,
    "    private let managedShipping: Bool",
    "    private let managedShipping: Bool\n    private let managedRoute: HostedManagedViewRoute?",
  );
  result = replaceExact(
    result,
    '        identity = try HostIdentity(\n            identifier: Bundle.main.bundleIdentifier!,\n            supportDirectory: directory.appendingPathComponent("support"))',
    '        managedRoute = managedShipping ? try HostedManagedViewRoute.load(directory: directory) : nil\n        guard !managedShipping || managedRoute?.hostIdentifier == Bundle.main.bundleIdentifier\n        else { throw HostWorkerError.rejected }\n        identity = try HostIdentity(\n            identifier: Bundle.main.bundleIdentifier!,\n            supportDirectory: managedRoute?.extensionID == "calendar"\n                ? directory.appendingPathComponent("support") : directory)',
  );
  result = replaceExact(
    result,
    "        let shipping = managedShipping\n        let sessions = HostExtensionSessions(defaults: defaults) { package in\n            HostWorker(",
    `        let shipping = managedShipping
        let route = managedRoute
        let sessions = HostExtensionSessions(defaults: defaults) { package in
            if let route, route.extensionID != "calendar" {
                try WorkerLifecycleFixture.requireSupported(package.id)
                guard route.extensionID == package.id, route.version == package.version,
                    route.hostABI == package.hostABI, route.sourceFingerprint == package.sourceFingerprint,
                    executable == directory.appendingPathComponent("Fixture.app/Contents/MacOS/Edith")
                else { throw HostWorkerError.rejected }
                let fixture = try WorkerLifecycleFixture(root: directory, hostIdentifier: fixtureIdentity.identifier)
                let helper = store.roleBundle(for: package, role: .helper)
                let role = FileManager.default.fileExists(atPath: helper.path)
                    ? helper : store.roleBundle(for: package, role: .app)
                try ExtensionCodeSignature.verifyDevelopment(role)
                try ExtensionCodeSignature.verifyDevelopment(directory.appendingPathComponent("Fixture.app"))
                let selection = WorkerLifecycleFixture.Selection(
                    extensionID: package.id, dataDirectory: fixtureIdentity.extensionDirectory(package.id),
                    roleDirectory: role, version: package.version, hostABI: package.hostABI)
                try FileManager.default.createDirectory(at: selection.dataDirectory,
                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try fixture.issue(selection, hostApp: directory.appendingPathComponent("Fixture.app"),
                    defaultsSuite: fixtureIdentity.extensionDefaultsSuite(package.id))
                setenv("EDITH_EXTENSION_FIXTURE_HOME", try fixture.home(for: package.id).path, 1)
            }
            return HostWorker(`,
  );
  result = replaceExact(
    result,
    "            try await marketplace.sessions.enable(package)\n            guard let enginePID",
    "            guard let route = managedRoute else { throw HostWorkerError.rejected }\n            try route.validate(package: package)\n            try await marketplace.sessions.enable(package)\n            guard let enginePID",
  );
  result = replaceExact(
    result,
    '                        extensionID: package.id, location: "main", section: package.id))',
    "                        extensionID: package.id, location: route.location, section: route.section))",
  );
  result = replaceExact(
    result,
    '                "originalDownloadedRole": true, "readonlyControlVerified": true,',
    `                "schema": 1, "location": route.location, "section": route.section,
                "factoryOverlay": route.factoryOverlay, "functionalActionsValidated": false,
                "featurePayloadUnchanged": !route.factoryOverlay,
                "productionExecutableUnchangedProof": false, "visible": false, "presentations": 2,`,
  );
  return result;
}

export function managedContextOverlay(source, sourceCommit) {
  assert.match(sourceCommit, /^[a-f0-9]{40}$/);
  return replaceExact(
    source,
    '        input["section"] = presentation.request.section',
    `        input["section"] = presentation.request.section
        if hostIdentifier.hasPrefix("com.pulkit.edith.tests.worker-") {
            let identity = try configuration.worker.identity()
            input["dataDirectory"] = identity.extensionDirectory(extensionID).path
            input["version"] = configuration.package.version
            input["hostABI"] = configuration.package.hostABI
            input["hostedManagedFixture"] = [
                "schema": 1, "sourceCommit": "${sourceCommit}",
                "selectedVersion": configuration.package.version,
                "hostABI": configuration.package.hostABI,
                "sourceFingerprint": configuration.package.sourceFingerprint,
                "roleDirectory": payload.appendingPathComponent(extensionID + "/app.bundle").path,
            ] as NSDictionary
        }`,
  );
}

export function managedFactoryOverlay(source, owner) {
  assert(["plugins", "studio"].includes(owner));
  return replaceExact(
    source,
    '                guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }',
    `                if input["hostedManagedFixture"] != nil {
                    guard HostedManagedFactoryAdmission.accepts(input, extensionID: "${owner}",
                        role: Bundle(for: ExtensionRuntime.self), worker: Bundle.main)
                    else { return ["ok": false] as NSDictionary }
                } else {
                    guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }
                }`,
  );
}
