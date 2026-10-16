import CoreFoundation
import CryptoKit
import ExtensionMarketplace
import Foundation

enum FunctionalFailure: Error {
    case invalid(String)
    case timeout(String)
    case unavailable(String)
}

enum FunctionalBytes {
    static func canonical(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
    }

    static func object(_ bytes: Data, maximum: Int = 1_048_576) throws -> [String: Any] {
        guard !bytes.isEmpty, bytes.count <= maximum,
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            try canonical(object) == bytes
        else { throw FunctionalFailure.invalid("canonical object") }
        return object
    }

    static func exact(_ object: [String: Any], _ keys: Set<String>) throws {
        guard Set(object.keys) == keys else { throw FunctionalFailure.invalid("closed fields") }
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length
            && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func uuid(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value && value.utf8.count == 36
            && value[value.index(value.startIndex, offsetBy: 14)] == "4"
            && "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)])
    }

    static func boolean(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let value = object[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID()
        else {
            throw FunctionalFailure.invalid("boolean")
        }
        return value.boolValue
    }

    static func integer(_ object: [String: Any], _ key: String) throws -> Int {
        guard let number = object[key] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue == Double(number.intValue)
        else { throw FunctionalFailure.invalid("integer") }
        return number.intValue
    }
}

final class FunctionalIssuer {
    private let key = Curve25519.Signing.PrivateKey()
    let sourceCommit: String
    let session: String

    init(sourceCommit: String, session: String) throws {
        guard FunctionalBytes.hex(sourceCommit, length: 40), FunctionalBytes.uuid(session)
        else { throw FunctionalFailure.invalid("issuer scope") }
        self.sourceCommit = sourceCommit
        self.session = session
    }

    var publicKey: Data { key.publicKey.rawRepresentation }

    static func sourcePackage(
        metadata: Data, owner: String, version: String,
        archiveSHA256: String, archiveBytes: Int
    ) throws -> ExtensionPackage {
        guard !metadata.isEmpty, metadata.count <= 1_048_576,
            let object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any],
            object["id"] as? String == owner, object["version"] as? String == version,
            ["1.0.0", "1.1.0"].contains(version),
            object["hostABI"] as? String == "edith-host-2",
            object["architecture"] as? String == "arm64",
            let fingerprint = object["sourceFingerprint"] as? String,
            FunctionalBytes.hex(fingerprint, length: 64),
            object["sha256"] as? String == archiveSHA256,
            try FunctionalBytes.integer(object, "downloadBytes") == archiveBytes
        else { throw FunctionalFailure.invalid("actual prepared original package metadata") }
        let packageFields: Set<String> = [
            "id", "version", "hostABI", "architecture", "minimumSystemVersion",
            "downloadURL", "sha256", "downloadBytes", "installedBytes", "dependencies",
        ]
        let projection = object.filter { packageFields.contains($0.key) }
        try FunctionalBytes.exact(projection, packageFields)
        let package = try JSONDecoder().decode(
            ExtensionPackage.self, from: FunctionalBytes.canonical(projection))
        try package.validate(repository: "pulkitxm/edith")
        guard package.dependencies.isEmpty else {
            throw FunctionalFailure.invalid("original package dependency scope")
        }
        return package
    }

    func signedCatalog(owner: String, version: String, root: FunctionalPinnedPath) throws -> Data {
        guard ExtensionPackage.validComponent(owner), ["1.0.0", "1.1.0"].contains(version) else {
            throw FunctionalFailure.invalid("source-owned catalog selection")
        }
        try root.requireCurrent()
        let directory = try FunctionalPinnedPath(
            root.url.appendingPathComponent("packages-" + owner + "-" + version), directory: true)
        let metadata = try FunctionalPinnedPath(
            directory.url.appendingPathComponent(owner + ".json"), directory: false,
            maximum: 1_048_576)
        let archive = try FunctionalPinnedPath(
            directory.url.appendingPathComponent(owner + ".zip"), directory: false,
            maximum: 536_870_912)
        let archiveBytes = try archive.read()
        let package = try Self.sourcePackage(
            metadata: metadata.read(), owner: owner, version: version,
            archiveSHA256: FunctionalBytes.digest(archiveBytes), archiveBytes: archiveBytes.count)
        let catalog = ExtensionCatalog(revision: version == "1.0.0" ? 1 : 2, packages: [package])
        try catalog.validate(repository: "pulkitxm/edith")
        let payload = try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(catalog)))
        let envelope = SignedExtensionCatalog(
            payload: payload, signature: try key.signature(for: payload))
        guard try envelope.verified(publicKey: publicKey, repository: "pulkitxm/edith") == catalog
        else {
            throw FunctionalFailure.invalid("same live catalog signature")
        }
        try root.requireCurrent()
        try directory.requireCurrent()
        try metadata.requireCurrent()
        try archive.requireCurrent()
        return try FunctionalBytes.canonical(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(envelope)))
    }

    #if !SWIFT_PACKAGE
    func sealPresentation(
        payload: Data, capability: HostedFunctionalActionContext, presentationID: String
    ) throws -> Data {
        guard capability.sourceCommit == sourceCommit, capability.session == session,
            capability.fixtureRoot.hasSuffix("/functional-fixture-" + session),
            capability.hostIdentifier == "com.pulkit.edith.tests.worker-" + session,
            FunctionalBytes.hex(capability.caseSHA256, length: 64),
            FunctionalBytes.uuid(presentationID), payload.count <= 1_048_576
        else {
            throw FunctionalFailure.invalid("source-owned presentation signature scope")
        }
        let observed = try FunctionalBytes.object(payload)
        try FunctionalBytes.exact(
            observed,
            [
                "schema", "authority", "execution", "capabilitySHA256", "recipeSHA256",
                "presentationID",
                "windowTitle", "before", "after", "steps", "stepInventories", "mutation",
                "authoritative", "presentationClosed", "leasesReleased",
            ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let capabilityBytes = try encoder.encode(capability)
        guard try FunctionalBytes.integer(observed, "schema") == 1,
            observed["authority"] as? String == "independent-hosted-producer",
            observed["execution"] as? String == "hosted-macos-native",
            observed["capabilitySHA256"] as? String == FunctionalBytes.digest(capabilityBytes),
            observed["presentationID"] as? String == presentationID,
            try FunctionalBytes.canonical(observed) == payload,
            let text = String(data: payload, encoding: .utf8)
        else {
            throw FunctionalFailure.invalid("exact source-owned presentation payload")
        }
        return try FunctionalBytes.canonical([
            "schema": 1, "payload": text,
            "signature": try key.signature(for: payload).base64EncodedString(),
        ])
    }

    #endif

    func seal(_ observed: [String: Any]) throws -> Data {
        guard observed["sourceCommit"] as? String == sourceCommit,
            observed["session"] as? String == session,
            try FunctionalBytes.integer(observed, "schema") == 1
        else { throw FunctionalFailure.invalid("observation scope") }
        let bytes = try FunctionalBytes.canonical(observed)
        guard bytes.count <= 1_048_576, let payload = String(data: bytes, encoding: .utf8)
        else { throw FunctionalFailure.invalid("observation size") }
        return try FunctionalBytes.canonical([
            "schema": 1, "payload": payload,
            "signature": try key.signature(for: bytes).base64EncodedString(),
        ])
    }
}

struct FunctionalHostedRunPins: Equatable, Sendable {
    let sourceCommit: String
    let mergeCommit: String
    let baseCommit: String
    let runID: Int
    let jobID: Int
    let runAttempt: Int
    let runnerName: String
    let workflowSHA256: String
}

enum FunctionalHostedRunAdmission {
    static let repositoryID = 1_289_153_439
    static let workflow = ".github/workflows/hosted-functional-actions.yml"

    static func requireEnvironment(
        _ environment: [String: String], pins: FunctionalHostedRunPins,
        event: [String: Any]
    ) throws {
        guard
            [pins.sourceCommit, pins.mergeCommit, pins.baseCommit].allSatisfy({
                FunctionalBytes.hex($0, length: 40)
            }),
            pins.sourceCommit != pins.mergeCommit, pins.runID > 0, pins.jobID > 0,
            pins.runAttempt > 0,
            !pins.runnerName.isEmpty, FunctionalBytes.hex(pins.workflowSHA256, length: 64),
            environment["GITHUB_ACTIONS"] == "true",
            environment["RUNNER_ENVIRONMENT"] == "github-hosted",
            environment["RUNNER_OS"] == "macOS",
            environment["GITHUB_REPOSITORY"] == "pulkitxm/edith",
            environment["GITHUB_REPOSITORY_ID"] == String(repositoryID),
            environment["GITHUB_EVENT_NAME"] == "pull_request",
            environment["GITHUB_REF"] == "refs/pull/1014/merge",
            environment["GITHUB_SHA"] == pins.mergeCommit,
            environment["EXPECTED_SOURCE_SHA"] == pins.sourceCommit,
            environment["GITHUB_RUN_ID"] == String(pins.runID),
            environment["FUNCTIONAL_JOB_ID"] == String(pins.jobID),
            environment["GITHUB_RUN_ATTEMPT"] == String(pins.runAttempt),
            environment["RUNNER_NAME"] == pins.runnerName,
            environment["EDITH_HOSTED_FUNCTIONAL_ACTIONS"] == "1",
            environment["EXTENSION_SWIFT_JOBS"] == "1",
            ["65671483", "320458784"].contains(environment["GITHUB_ACTOR_ID"] ?? ""),
            try FunctionalBytes.integer(event, "number") == 1014,
            let repository = event["repository"] as? [String: Any],
            let pull = event["pull_request"] as? [String: Any]
        else { throw FunctionalFailure.invalid("genuine disposable PR hosted environment") }
        try requireRepository(repository)
        try requirePull(pull, pins: pins)
    }

    static func requireRepository(_ repository: [String: Any]) throws {
        guard repository["full_name"] as? String == "pulkitxm/edith",
            try FunctionalBytes.integer(repository, "id") == repositoryID
        else { throw FunctionalFailure.invalid("actual repository identity") }
    }

    static func requirePull(_ pull: [String: Any], pins: FunctionalHostedRunPins) throws {
        guard try FunctionalBytes.integer(pull, "number") == 1014,
            pull["state"] as? String == "open",
            pull["merge_commit_sha"] as? String == pins.mergeCommit,
            let head = pull["head"] as? [String: Any], let base = pull["base"] as? [String: Any],
            head["sha"] as? String == pins.sourceCommit, base["sha"] as? String == pins.baseCommit,
            head["ref"] as? String == "feat/extension-marketplace",
            base["ref"] as? String == "main",
            let headRepository = head["repo"] as? [String: Any],
            let baseRepository = base["repo"] as? [String: Any]
        else { throw FunctionalFailure.invalid("current original PR head and merge") }
        try requireRepository(headRepository)
        try requireRepository(baseRepository)
    }

    static func validate(
        pins: FunctionalHostedRunPins, pull: [String: Any], run: [String: Any],
        job: [String: Any], merge: [String: Any], sourceWorkflow: Data, mergeWorkflow: Data
    ) throws {
        try requirePull(pull, pins: pins)
        guard try FunctionalBytes.integer(run, "id") == pins.runID,
            try FunctionalBytes.integer(run, "run_attempt") == pins.runAttempt,
            run["head_sha"] as? String == pins.sourceCommit,
            run["event"] as? String == "pull_request",
            run["path"] as? String == workflow, run["status"] as? String == "in_progress",
            run["conclusion"] is NSNull, let repository = run["repository"] as? [String: Any],
            let actor = run["actor"] as? [String: Any],
            let triggeringActor = run["triggering_actor"] as? [String: Any],
            [65_671_483, 320_458_784].contains(try FunctionalBytes.integer(actor, "id")),
            [65_671_483, 320_458_784].contains(try FunctionalBytes.integer(triggeringActor, "id")),
            run["head_branch"] as? String == "feat/extension-marketplace",
            let pulls = run["pull_requests"] as? [[String: Any]], pulls.count == 1,
            try FunctionalBytes.integer(pulls[0], "number") == 1014,
            let runHead = pulls[0]["head"] as? [String: Any],
            let runBase = pulls[0]["base"] as? [String: Any],
            runHead["sha"] as? String == pins.sourceCommit,
            runBase["sha"] as? String == pins.baseCommit,
            runHead["ref"] as? String == "feat/extension-marketplace",
            runBase["ref"] as? String == "main",
            let runHeadRepository = runHead["repo"] as? [String: Any],
            let runBaseRepository = runBase["repo"] as? [String: Any],
            try FunctionalBytes.integer(runHeadRepository, "id") == repositoryID,
            try FunctionalBytes.integer(runBaseRepository, "id") == repositoryID,
            try FunctionalBytes.integer(job, "id") == pins.jobID,
            try FunctionalBytes.integer(job, "run_id") == pins.runID,
            try FunctionalBytes.integer(job, "run_attempt") == pins.runAttempt,
            job["head_sha"] as? String == pins.sourceCommit,
            job["name"] as? String == "functional-build",
            job["status"] as? String == "in_progress", job["conclusion"] is NSNull,
            job["runner_name"] as? String == pins.runnerName,
            let labels = job["labels"] as? [String], labels.contains("macos-26"),
            !labels.contains("self-hosted"),
            merge["sha"] as? String == pins.mergeCommit,
            let parents = merge["parents"] as? [[String: Any]], parents.count == 2,
            parents.compactMap({ $0["sha"] as? String }) == [pins.baseCommit, pins.sourceCommit],
            sourceWorkflow == mergeWorkflow,
            FunctionalBytes.digest(sourceWorkflow) == pins.workflowSHA256
        else {
            throw FunctionalFailure.invalid("live hosted job and exact source merge provenance")
        }
        try requireRepository(repository)
    }

    @MainActor static func observe(pins: FunctionalHostedRunPins, environment: [String: String])
        async throws -> [String: Any]
    {
        guard let token = environment["GITHUB_TOKEN"], !token.isEmpty,
            let eventPath = environment["GITHUB_EVENT_PATH"]
        else { throw FunctionalFailure.invalid("hosted read-only API authority") }
        let eventBytes = try FunctionalPinnedPath(
            URL(fileURLWithPath: eventPath), directory: false, maximum: 4_194_304
        ).read()
        guard let event = try JSONSerialization.jsonObject(with: eventBytes) as? [String: Any]
        else { throw FunctionalFailure.invalid("actual hosted event object") }
        try requireEnvironment(environment, pins: pins, event: event)
        func get(_ path: String) async throws -> [String: Any] {
            guard let url = URL(string: "https://api.github.com/repos/pulkitxm/edith/" + path)
            else { throw FunctionalFailure.invalid("hosted API path") }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            request.setValue("edith-functional-verification", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                response.url?.host == "api.github.com", data.count <= 4_194_304,
                let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw FunctionalFailure.invalid("actual hosted API observation") }
            return value
        }
        let pull = try await get("pulls/1014")
        let run = try await get(
            "actions/runs/" + String(pins.runID) + "/attempts/" + String(pins.runAttempt))
        let job = try await get("actions/jobs/" + String(pins.jobID))
        let merge = try await get("commits/" + pins.mergeCommit)
        func workflowBytes(_ commit: String) async throws -> Data {
            let value = try await get("contents/" + workflow + "?ref=" + commit)
            guard value["encoding"] as? String == "base64", let text = value["content"] as? String,
                let bytes = Data(base64Encoded: text.replacingOccurrences(of: "\n", with: "")),
                bytes.count <= 262_144
            else { throw FunctionalFailure.invalid("actual workflow source bytes") }
            return bytes
        }
        let sourceWorkflow = try await workflowBytes(pins.sourceCommit)
        let mergeWorkflow = try await workflowBytes(pins.mergeCommit)
        try validate(
            pins: pins, pull: pull, run: run, job: job, merge: merge,
            sourceWorkflow: sourceWorkflow, mergeWorkflow: mergeWorkflow)
        return ["sourceCommit": pins.sourceCommit, "run": run, "job": job]
    }
}
