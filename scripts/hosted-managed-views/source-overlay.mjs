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
                    route.hostABI == package.hostABI, route.packageSHA256 == package.sha256,
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
    `                let handle = try await manager.scene(
                    for: EdithHostCore.HostExtensionContentRequest(
                        extensionID: package.id, location: route.location, section: route.section))`,
    `                let request = EdithHostCore.HostExtensionContentRequest(
                    extensionID: package.id, location: route.location, section: route.section)
                let handle: HostRemoteSceneHandle
                do {
                    handle = try await manager.scene(for: request)
                } catch HostRemoteAvailabilityError.approvalRequired {
                    guard uiProcesses.isEmpty else { throw HostWorkerError.rejected }
                    _ = try await awaitHostedManagedApproval(
                        directory: directory, hostIdentifier: identity.identifier,
                        extensionID: package.id,
                        workerIdentifier: identity.identifier + ".extension." + package.id + ".worker")
                    handle = try await manager.scene(for: request)
                }`,
  );
  result = replaceExact(
    result,
    '                "originalDownloadedRole": true, "readonlyControlVerified": true,',
    `                "schema": 1, "location": route.location, "section": route.section,
                "factoryOverlay": route.factoryOverlay, "functionalActionsValidated": false,
                "featurePayloadUnchanged": !route.factoryOverlay,
                "productionExecutableUnchangedProof": false, "visible": false, "presentations": 2,`,
  );
  result = replaceExact(
    result,
    "    private var previousUI: HostRemoteProcessIdentity?",
    `    private var previousUI: HostRemoteProcessIdentity?
    private var managedVerification: Task<Void, Never>?
    private var managedTermination = false
    private var managedSignal: DispatchSourceSignal?
    private var managedPeers: [[String: Any]] = []

    private func recordManagedPeer(pid: Int32, role: String) async throws {
        guard pid > 1, ["engine", "ui"].contains(role), managedPeers.count < 8,
            !managedPeers.contains(where: { ($0["pid"] as? Int32) == pid })
        else { throw HostWorkerError.rejected }
        managedPeers.append(["pid": pid, "role": role])
        let url = directory.appendingPathComponent("managed-peers.json")
        try JSONSerialization.data(withJSONObject: managedPeers, options: .sortedKeys)
            .write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let acknowledgement = directory.appendingPathComponent("managed-peer-ack.json")
        let deadline = ContinuousClock.now + .seconds(10)
        repeat {
            try Task.checkCancellation()
            if let attributes = try? FileManager.default.attributesOfItem(atPath: acknowledgement.path),
                attributes[.type] as? FileAttributeType == .typeRegular,
                attributes[.ownerAccountID] as? UInt32 == getuid(),
                attributes[.posixPermissions] as? Int == 0o600,
                (attributes[.size] as? Int ?? 16385) <= 16384,
                let data = try? Data(contentsOf: acknowledgement),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                object["sourceCommit"] as? String == managedRoute?.sourceCommit,
                object["extensionID"] as? String == package.id,
                let processes = object["processes"] as? [[String: Any]],
                processes.contains(where: { ($0["pid"] as? Int32) == pid && $0["role"] as? String == role })
            { return }
            try await Task.sleep(for: .milliseconds(20))
        } while ContinuousClock.now < deadline
        throw HostWorkerError.timedOut
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard managedShipping else { return .terminateNow }
        guard !managedTermination else { return .terminateCancel }
        managedTermination = true
        managedVerification?.cancel()
        Task { [self] in
            await managedVerification?.value
            activation?.cancel()
            try? await manager.stop(extensionID: package.id)
            let stopped = await marketplace.sessions.shutdown()
            managedSignal?.cancel()
            managedSignal = nil
            sender.reply(toApplicationShouldTerminate: stopped)
        }
        return .terminateLater
    }`,
  );
  result = replaceExact(
    result,
    `        if registrationOnly {
            Task {`,
    `        if registrationOnly {
            if managedShipping {
                signal(SIGTERM, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
                source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
                source.resume()
                managedSignal = source
            }
            managedVerification = Task {`,
  );
  result = replaceExact(
    result,
    "            var uiProcesses: [HostRemoteProcessIdentity] = []",
    '            try await recordManagedPeer(pid: enginePID, role: "engine")\n            var uiProcesses: [HostRemoteProcessIdentity] = []',
  );
  result = replaceExact(
    result,
    "                uiProcesses.append(peer)",
    '                try await recordManagedPeer(pid: peer.pid, role: "ui")\n                uiProcesses.append(peer)',
  );
  return result;
}

export function managedContextOverlay(source, sourceCommit, fingerprints) {
  assert.match(sourceCommit, /^[a-f0-9]{40}$/);
  assert.deepEqual(Object.keys(fingerprints).sort(), ["plugins", "studio"]);
  for (const value of Object.values(fingerprints))
    assert.match(value, /^[a-f0-9]{64}$/);
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
                "sourceFingerprint": ["plugins": "${fingerprints.plugins}", "studio": "${fingerprints.studio}"][extensionID] ?? "",
                "packageSHA256": configuration.package.sha256,
                "roleDirectory": payload.appendingPathComponent(extensionID + "/app.bundle").path,
            ] as NSDictionary
        }`,
  );
}

export function managedFactoryOverlay(source, owner) {
  assert(["plugins", "studio"].includes(owner));
  assert(
    !source.includes("HostedManagedFactoryAdmission.accepts("),
    "Managed factory source already contains fixture admission",
  );
  const ordinaryAdmission = {
    plugins: `            #else
            do { _ = try admitOrdinaryContext(input) } catch {
                fixtureRejected = true; return ["ok": false] as NSDictionary
            }
            #endif`,
    studio:
      '                guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }',
  }[owner];
  const managedAdmission = `if input["hostedManagedFixture"] != nil {
                guard ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                    input["hostedFunctionalFixture"] == nil,
                    HostedManagedFactoryAdmission.accepts(input, extensionID: "${owner}",
                    role: Bundle(for: ExtensionRuntime.self), worker: Bundle.main)
                else { return ["ok": false] as NSDictionary }
            } else {`;
  const replacement =
    owner === "plugins"
      ? `            #else
            ${managedAdmission}
                do { _ = try admitOrdinaryContext(input) } catch {
                    fixtureRejected = true; return ["ok": false] as NSDictionary
                }
            }
            #endif`
      : `                ${managedAdmission}
                    guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }
                }`;
  return replaceExact(source, ordinaryAdmission, replacement);
}
