import Darwin
import Foundation

@main
struct WorkerLifecycleFixtureTests {
    static func rejected(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw NSError(domain: "FixtureTest", code: 1)
    }

    static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(
            "worker-marker-" + UUID().uuidString
        )
        .resolvingSymlinksInPath()
        try manager.createDirectory(
            at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        let identifier = "com.pulkit.edith.tests.worker-" + UUID().uuidString
        let issuer = try WorkerLifecycleFixture(root: root, hostIdentifier: identifier)
        let app = root.appendingPathComponent("Fixture.app", isDirectory: true)
        try manager.createDirectory(at: app, withIntermediateDirectories: false)
        let slot = String(identifier.dropFirst("com.pulkit.edith.tests.".count))
        let base = root.appendingPathComponent("Edith Tests").appendingPathComponent(slot)
        let data = base.appendingPathComponent("Data/focusDim")
        let suite = identifier + ".extensions.focusDim"
        func selection(_ version: String) throws -> WorkerLifecycleFixture.Selection {
            let role = base.appendingPathComponent(
                "Extensions/focusDim/1/arm64/" + version
                    + "/focusDim/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/focusDim/helper.bundle"
            )
            try manager.createDirectory(
                at: role, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            return .init(
                extensionID: "focusDim", dataDirectory: data, roleDirectory: role,
                version: version, hostABI: "1")
        }
        try manager.createDirectory(
            at: data, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let first = try selection("1.0.0")
        let second = try selection("1.1.0")
        let home = try issuer.home(for: "focusDim")
        let marker = home.appendingPathComponent("worker-fixture.json")
        try issuer.issue(first, hostApp: app, defaultsSuite: suite)
        try issuer.validateExact(first, hostApp: app, defaultsSuite: suite)
        #if WORKER_ADMISSION_CONTRACT
        let context: NSDictionary = [
            "hostIdentifier": identifier, "defaultsSuite": suite,
            "dataDirectory": data.path,
        ]
        let environment = [
            "EDITH_APPLICATION_IDENTIFIER": identifier,
            "EDITH_EXTENSION_ID": "focusDim", "EDITH_SHARED_DEFAULTS_SUITE": suite,
            "EDITH_EXTENSION_DATA_ROOT": data.path, "EDITH_EXTENSION_FIXTURE_HOME": home.path,
        ]
        let admitted = try WorkerFixtureAdmission.admit(
            extensionID: "focusDim",
            context: context, environment: environment, hostIdentifier: identifier,
            hostBundle: app, roleDirectory: first.roleDirectory,
            roleIdentifier: "com.pulkit.edith.extensions.focusDim.helper",
            version: first.version, hostABI: first.hostABI)
        guard admitted?.dataDirectory.path == data.path else {
            throw WorkerLifecycleFixtureError.marker
        }
        try rejected {
            _ = try WorkerFixtureAdmission.admit(
                extensionID: "focusDim",
                context: context, environment: environment, hostIdentifier: identifier,
                hostBundle: app, roleDirectory: second.roleDirectory,
                roleIdentifier: "com.pulkit.edith.extensions.focusDim.helper",
                version: second.version, hostABI: second.hostABI)
        }
        print(
            "utility owner strict admission parser accepted current marker and rejected stale version"
        )
        #endif

        try rejected { try issuer.validateExact(second, hostApp: app, defaultsSuite: suite) }
        try issuer.issue(second, hostApp: app, defaultsSuite: suite)
        try rejected { try issuer.validateExact(first, hostApp: app, defaultsSuite: suite) }
        try rejected { try issuer.remove(first) }
        let original = try Data(contentsOf: marker)
        let originalValues = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        for (key, value) in [
            ("schema", true as Any), ("schema", 2),
            ("hostIdentifier", "com.pulkit.edith.tests.worker-foreign"),
            ("hostIdentifier", "com.pulkit.edith.tests.worker-" + UUID().uuidString),
            ("extensionID", "music"), ("dataDirectory", root.path),
            ("roleDirectory", first.roleDirectory.path),
            ("version", "1.0.0"), ("hostABI", "old"), ("unexpected", "value"),
        ] {
            var values = originalValues
            values[key] = value
            try JSONSerialization.data(withJSONObject: values).write(to: marker)
            try rejected { try issuer.validateExact(second, hostApp: app, defaultsSuite: suite) }
            try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
            try original.write(to: marker)
        }
        for bytes in [Data(), Data(repeating: 65, count: 16_385), Data("[]".utf8), Data("{".utf8)] {
            try bytes.write(to: marker)
            try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        }
        try original.write(to: marker)
        try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: marker.path)
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        try rejected { try issuer.remove(second) }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.path)
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try issuer.remove(second)
        let foreign = root.appendingPathComponent("foreign.json")
        try original.write(to: foreign)
        try manager.createSymbolicLink(at: marker, withDestinationURL: foreign)
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        try rejected { try issuer.remove(second) }
        guard try Data(contentsOf: foreign) == original else {
            throw WorkerLifecycleFixtureError.marker
        }
        try manager.removeItem(at: marker)
        guard mkfifo(marker.path, 0o600) == 0 else { throw WorkerLifecycleFixtureError.path }
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        try manager.removeItem(at: marker)
        guard link(foreign.path, marker.path) == 0 else { throw WorkerLifecycleFixtureError.path }
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: suite) }
        try manager.removeItem(at: marker)
        try rejected {
            _ = try WorkerLifecycleFixture(
                root: root, hostIdentifier: "com.pulkit.edith.tests.worker-named")
        }
        try rejected {
            try issuer.issue(
                second, hostApp: root.appendingPathComponent("UpdatedFixture.app"),
                defaultsSuite: suite)
        }
        try rejected { try issuer.issue(second, hostApp: app, defaultsSuite: identifier + ".host") }
        for mode in [0o755, 0o740] {
            try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
            try rejected { _ = try WorkerLifecycleFixture(root: root, hostIdentifier: identifier) }
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let alias = root.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: root)
        try rejected { _ = try WorkerLifecycleFixture(root: alias, hostIdentifier: identifier) }
        let canceled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try issuer.issue(second, hostApp: app, defaultsSuite: suite)
        }
        do {
            try await canceled.value; throw WorkerLifecycleFixtureError.marker
        } catch is CancellationError {}
        guard !manager.fileExists(atPath: marker.path),
            try manager.contentsOfDirectory(atPath: home.path).isEmpty
        else {
            throw WorkerLifecycleFixtureError.marker
        }
        try issuer.issue(second, hostApp: app, defaultsSuite: suite)
        try issuer.validateExact(second, hostApp: app, defaultsSuite: suite)
        try issuer.remove(second)
        try rejected { try WorkerLifecycleFixture.requireSupported("unknown") }
        try rejected { _ = try issuer.home(for: "futureWorker") }
        guard !manager.fileExists(atPath: root.appendingPathComponent("futureWorker-home").path)
        else {
            throw WorkerLifecycleFixtureError.path
        }
        for id in WorkerLifecycleFixture.supportedIDs {
            try WorkerLifecycleFixture.requireSupported(id)
        }
        let allIDs = WorkerLifecycleFixture.supportedIDs
        guard allIDs.count == 39 else { throw WorkerLifecycleFixtureError.identity }
        for id in allIDs.subtracting(["calendar"]) {
            let selectedData = base.appendingPathComponent("Data").appendingPathComponent(id)
            let admittedRole =
                WorkerLifecycleFixture.inertIDs.contains(id)
                    && !["music", "plugins", "studio"].contains(id) ? "helper" : "app"
            let role = base.appendingPathComponent(
                "Extensions/" + id + "/1/arm64/1.1.0/" + id
                    + "/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                    + id + "/" + admittedRole + ".bundle")
            try manager.createDirectory(
                at: selectedData, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(
                at: role, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let selected = WorkerLifecycleFixture.Selection(
                extensionID: id,
                dataDirectory: selectedData, roleDirectory: role, version: "1.1.0", hostABI: "1")
            if WorkerLifecycleFixture.inertIDs.contains(id) {
                let wrongRole = role.deletingLastPathComponent().appendingPathComponent(
                    admittedRole == "app" ? "helper.bundle" : "app.bundle")
                try manager.createDirectory(at: wrongRole, withIntermediateDirectories: false)
                let rejectedRole = WorkerLifecycleFixture.Selection(
                    extensionID: id, dataDirectory: selectedData, roleDirectory: wrongRole,
                    version: selected.version, hostABI: selected.hostABI)
                try rejected {
                    try issuer.issue(
                        rejectedRole, hostApp: app, defaultsSuite: identifier + ".extensions." + id)
                }
            }
            try issuer.issue(
                selected, hostApp: app, defaultsSuite: identifier + ".extensions." + id)
            try issuer.validateExact(
                selected, hostApp: app, defaultsSuite: identifier + ".extensions." + id)
            #if WORKER_ADMISSION_CONTRACT
            if WorkerLifecycleFixture.inertIDs.contains(id) {
                let selectedHome = try issuer.home(for: id)
                let context: NSDictionary = [
                    "hostIdentifier": identifier, "defaultsSuite": identifier + ".extensions." + id,
                    "dataDirectory": selectedData.path,
                ]
                let environment = [
                    "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": id,
                    "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions." + id,
                    "EDITH_EXTENSION_DATA_ROOT": selectedData.path,
                    "EDITH_EXTENSION_FIXTURE_HOME": selectedHome.path,
                ]
                let admission = try WorkerFixtureAdmission.admit(
                    extensionID: id, context: context, environment: environment,
                    hostIdentifier: identifier, hostBundle: app, roleDirectory: role,
                    roleIdentifier: "com.pulkit.edith.extensions." + id + "." + admittedRole,
                    version: selected.version, hostABI: selected.hostABI)
                guard admission?.extensionID == id else { throw WorkerLifecycleFixtureError.marker }
            }
            #endif
            try issuer.remove(selected)
        }
        print(
            "all39 inventory marker coverage: 38 generic IDs, Calendar covered by its unchanged strict issuer tests"
        )
        print(
            "worker fixture marker tests passed: issuance, exact version, schema, UUID, foreign paths, permissions, symlink, hardlink, FIFO, bounds, cancellation, cleanup, fail-closed startup"
        )
    }
}
