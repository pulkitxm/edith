import Darwin
import Foundation

@main
struct HostWorkerStartAdmissionTests {
    enum Failure: Error { case assertion, signature, configuration, start }

    static func require(_ condition: Bool) throws {
        guard condition else { throw Failure.assertion }
    }

    struct Fixture {
        let root: URL
        let home: URL
        let identifier: String
        let owner: String
        let support: URL
        let host: URL
        let data: URL
        let role: HostWorkerStartAdmission.FixtureRole
        let marker: URL
        let values: [String: Any]
        let environment: [String: String]

        init(owner: String) throws {
            let manager = FileManager.default
            let calendar = owner == "calendar"
            guard let temporary = ProcessInfo.processInfo.environment["TMPDIR"] else {
                throw Failure.assertion
            }
            root = URL(fileURLWithPath: temporary, isDirectory: true)
                .appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
            home = root.appendingPathComponent(calendar ? "synthetic-data" : owner + "-home")
            identifier =
                "com.pulkit.edith.tests." + (calendar ? "remote-" : "worker-")
                + UUID().uuidString
            self.owner = owner
            support = calendar ? root.appendingPathComponent("support") : root
            host = root.appendingPathComponent(
                calendar ? "Host.app" : "Fixture.app", isDirectory: true)
            let identity = support.appendingPathComponent(
                "Edith Tests/" + identifier.dropFirst("com.pulkit.edith.tests.".count))
            data = identity.appendingPathComponent("Data/" + owner)
            let package = identity.appendingPathComponent(
                "Extensions/" + owner + "/1/arm64/1.0.0/" + owner)
            let helperOwners: Set<String> = [
                "focusDim", "micMute", "systemStats", "windowSweaters", "colorPicker", "emoji",
                "presenter", "keystrokeHighlight", "keepAwake", "notchShelf",
            ]
            let name = helperOwners.contains(owner) ? "helper" : "app"
            let directory = package.appendingPathComponent(
                "ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/"
                    + owner + "/" + name + ".bundle")
            role = .init(
                directory: directory,
                identifier: "com.pulkit.edith.extensions." + owner + "." + name,
                version: "1.0.0", hostABI: "1")
            for path in [root, home, host, data, directory] {
                try manager.createDirectory(
                    at: path, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            marker = home.appendingPathComponent(
                calendar ? "calendar-fixture.json" : "worker-fixture.json")
            if calendar {
                values = [
                    "schema": 1, "hostIdentifier": identifier, "dataDirectory": data.path,
                    "packageDirectory": package.path,
                ]
            } else {
                values = [
                    "schema": 1, "hostIdentifier": identifier, "extensionID": owner,
                    "dataDirectory": data.path, "roleDirectory": directory.path,
                    "version": "1.0.0", "hostABI": "1",
                ]
            }
            environment = [
                "EDITH_APPLICATION_IDENTIFIER": identifier, "EDITH_EXTENSION_ID": owner,
                "EDITH_SHARED_DEFAULTS_SUITE": identifier + ".extensions." + owner,
                "EDITH_EXTENSION_DATA_ROOT": data.path, "EDITH_EXTENSION_FIXTURE_HOME": home.path,
            ]
            try write(values)
        }

        func write(_ values: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: values).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }

        func admit(
            environment: [String: String]? = nil, identifier: String? = nil,
            suite: String? = nil, roles: [HostWorkerStartAdmission.FixtureRole]? = nil
        ) throws {
            try HostWorkerStartAdmission.admitFixture(
                identifier: identifier ?? self.identifier, owner: owner, version: "1.0.0",
                hostABI: "1",
                supportDirectory: support, hostBundle: host, dataDirectory: data,
                defaultsSuite: suite ?? self.identifier + ".extensions." + owner,
                roles: roles ?? [role], environment: environment ?? self.environment)
        }
    }

    static func rejected(_ admission: () throws -> [String]) throws {
        var writes: [String: String] = [:]
        var accepted: [String] = []
        var rejected = false
        do {
            try HostWorkerStartAdmission.perform(
                admit: admission,
                appearance: {
                    writes["theme"] = "teal"; writes["appearance"] = "dark"; writes["zoom"] = "1.2"
                },
                start: { accepted.append($0) })
        } catch { rejected = true }
        try require(rejected && writes.isEmpty && accepted.isEmpty)
    }

    static func main() {
        do { try run() } catch {
            print("start admission failed: \(error)")
            exit(1)
        }
    }

    static func run() throws {
        try rejected { throw Failure.configuration }
        try rejected {
            for role in ["helper", "app"] {
                if role == "app" { throw Failure.signature }
            }
            return ["helper", "app"]
        }
        try rejected { [] }
        var events: [String] = []
        var writes: [String: String] = [:]
        try HostWorkerStartAdmission.perform(
            admit: {
                events.append("configuration")
                for role in ["helper", "app"] { events.append("signature:" + role) }
                events.append("fixture")
                return ["helper", "app"]
            },
            appearance: {
                for (key, value) in [("theme", "teal"), ("appearance", "dark"), ("zoom", "1.2")] {
                    writes[key] = value; events.append("preference:" + key)
                }
            },
            start: { role in
                try require(writes == ["theme": "teal", "appearance": "dark", "zoom": "1.2"])
                events.append("role:" + role)
            })
        try require(
            events == [
                "configuration", "signature:helper", "signature:app", "fixture", "preference:theme",
                "preference:appearance", "preference:zoom", "role:helper", "role:app",
            ])
        var retained: [String] = []
        do {
            try HostWorkerStartAdmission.perform(
                admit: { ["helper", "app"] }, appearance: {},
                start: { role in
                    retained.append(role)
                    if role == "app" { throw Failure.start }
                })
            throw Failure.assertion
        } catch Failure.start {}
        try require(retained == ["helper", "app"])
        let manifest =
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: URL(fileURLWithPath: "Extensions/manifest.json")))
            as! [[String: Any]]
        let owners = manifest.filter { $0["contractVersion"] as? Int == 1 }.map {
            $0["id"] as! String
        }
        try require(owners.count == 40 && Set(owners) == HostWorkerStartAdmission.fixtureOwners)
        for owner in owners {
            let fixture = try Fixture(owner: owner)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            do { try fixture.admit() } catch {
                print("fixture rejected: \(owner)")
                throw error
            }
        }
        for owner in ["focusDim", "music", "clipboard", "calendar", "futureWorker"] {
            let fixture = try Fixture(owner: owner)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if owner == "futureWorker" {
                try rejected {
                    try fixture.admit(); return [owner]
                }
                continue
            }
            try fixture.admit()
            try require(
                HostWorkerStartAdmission.hasFixtureIntent(
                    identifier: fixture.identifier, environment: fixture.environment))
            for key in fixture.environment.keys {
                var environment = fixture.environment
                environment[key] = "malformed"
                try rejected {
                    try fixture.admit(environment: environment); return [owner]
                }
                environment.removeValue(forKey: key)
                try rejected {
                    try fixture.admit(environment: environment); return [owner]
                }
            }
            for identifier in ["com.pulkit.edith", "com.pulkit.edith.tests.worker-invalid"] {
                try rejected {
                    try fixture.admit(identifier: identifier); return [owner]
                }
            }
            for suite in [
                "com.pulkit.edith.shared", fixture.identifier, fixture.identifier + ".host",
            ] {
                try rejected {
                    try fixture.admit(suite: suite); return [owner]
                }
            }
            try rejected {
                try fixture.admit(roles: []); return [owner]
            }
            let wrongRole = HostWorkerStartAdmission.FixtureRole(
                directory: fixture.role.directory, identifier: fixture.role.identifier,
                version: "1.1.0", hostABI: "1")
            try rejected {
                try fixture.admit(roles: [wrongRole]); return [owner]
            }
            for (key, value) in [
                ("schema", true as Any), ("schema", 2), ("hostIdentifier", "foreign"),
                ("dataDirectory", fixture.root.path), ("unexpected", "value"),
            ] {
                var values = fixture.values
                values[key] = value
                try fixture.write(values)
                try rejected {
                    try fixture.admit(); return [owner]
                }
            }
            try fixture.write(fixture.values)
            let manager = FileManager.default
            try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.marker.path)
            try rejected {
                try fixture.admit(); return [owner]
            }
            try manager.removeItem(at: fixture.marker)
            try rejected {
                try fixture.admit(); return [owner]
            }
            try require(mkfifo(fixture.marker.path, 0o600) == 0)
            try rejected {
                try fixture.admit(); return [owner]
            }
            try manager.removeItem(at: fixture.marker)
            let target = fixture.home.appendingPathComponent("foreign.json")
            try JSONSerialization.data(withJSONObject: fixture.values).write(to: target)
            try manager.createSymbolicLink(at: fixture.marker, withDestinationURL: target)
            try rejected {
                try fixture.admit(); return [owner]
            }
            try manager.removeItem(at: fixture.marker)
            try fixture.write(fixture.values)
            try require(link(fixture.marker.path, target.appendingPathExtension("link").path) == 0)
            try rejected {
                try fixture.admit(); return [owner]
            }
        }
        for environment in [
            ["EDITH_EXTENSION_FIXTURE_HOME": ""],
            ["EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.tests.invalid"],
            ["EDITH_SHARED_DEFAULTS_SUITE": "com.pulkit.edith.tests.invalid"],
        ] {
            try require(
                HostWorkerStartAdmission.hasFixtureIntent(
                    identifier: "com.pulkit.edith", environment: environment))
        }
        try require(
            !HostWorkerStartAdmission.hasFixtureIntent(
                identifier: "com.pulkit.edith", environment: [:]))
        print(
            "start admission passed: zero preference writes and accepted roles on rejection; all admission before initial theme/appearance/zoom; retained partial-start roles; strict helper/app, conditional owner and Calendar fixture rejection"
        )
    }
}
