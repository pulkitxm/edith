import EdithHostCore
import Foundation

@MainActor
public final class FixtureWorkerEngine: HostWorkerEngine {
    private let mode: String
    private let record: URL?
    private let channel: HostWorkerChannel
    private var configuration: HostWorkerConfiguration?
    private var prepareCount = 0
    private var pendingShows: [UUID: CheckedContinuation<Bool, Never>] = [:]

    init(mode: String, record: URL? = nil, channel: HostWorkerChannel) {
        self.mode = mode
        self.record = record
        self.channel = channel
    }

    public static func factory(mode: String, record: URL? = nil)
        -> @MainActor (HostWorkerChannel) -> any HostWorkerEngine
    {
        { FixtureWorkerEngine(mode: mode, record: record, channel: $0) }
    }

    public func deliver(_ reply: HostWorkerNavigationReply) throws {
        if mode == "folder-choice", let record {
            try JSONEncoder().encode(reply).write(to: record)
        }
        pendingShows.removeValue(forKey: reply.token)?.resume(returning: reply.ok)
    }

    public func perform(_ request: HostWorkerRequest) async -> HostWorkerResponse {
        let operation = request.operation
        if mode == "timeout" || (mode == "ignore-stop" && operation == "stop") {
            try? await Task.sleep(for: .seconds(30))
        }
        var ok = mode != "reject"
        var version: String?
        var message: String?
        if ["prepareDisable", "prepareApplicationQuit", "stop"].contains(operation) {
            version = configuration?.version
            if operation == "prepareDisable", mode == "wrong-disable-version" { version = "99.0.0" }
        }
        if operation == "stop", mode == "reject-stop-unless-recovery",
            configuration?.recoveryOnly == false
        {
            ok = false
        }
        if operation == "show", mode == "folder-choice", let configuration {
            let event = HostWorkerNavigationRequest(
                configuration: configuration, section: "agentActivity", presentationID: UUID(),
                location: "settings", folderChoice: true)
            let accepted = await waitForReply(event)
            return HostWorkerResponse(token: request.token, ok: accepted)
        }
        if operation == "show", mode.hasPrefix("navigation"), let event = navigationEvent() {
            switch mode {
            case "navigation-ack", "navigation-rejected", "navigation-disconnect":
                let accepted = await waitForReply(event)
                return HostWorkerResponse(token: request.token, ok: accepted)
            case "navigation-cancel":
                try? channel.navigate(event)
                try? channel.cancelNavigation(
                    HostWorkerNavigationCancel(token: event.token, configuration: configuration!))
            default:
                try? channel.navigate(event)
            }
        }
        if operation == "prepareDisable", mode == "navigation-disable",
            let event = navigationEvent()
        {
            try? channel.navigate(event)
        }
        let lifecycle = ["prepareDisable", "prepareApplicationQuit", "stop"]
        if mode == "quit-policy", lifecycle.contains(operation) {
            append(request)
        }
        if operation == "prepareApplicationQuit", mode == "reject-quit" { ok = false }
        if operation == "prepareDisable" {
            prepareCount += 1
            let rejects = mode == "reject-disable-once" && prepareCount == 1
            if mode == "reject-disable-always" || rejects {
                ok = false
                message = "Restore sleep settings and try again."
            }
            if mode == "late-disable", prepareCount == 1 {
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        if ["synchronize", "ambientPolicy"].contains(operation) {
            if ["record-sync", "wrong-sync-version"].contains(mode) { append(request) }
            version = configuration?.version
            if mode == "wrong-sync-version" {
                version = "99.0.0"
            } else {
                configuration = request.configuration
            }
        }
        if operation == "start", let next = request.configuration {
            configuration = next
            if mode == "navigation-early", let event = navigationEvent() {
                try? channel.navigate(event)
            }
            if mode == "require-recovery", !next.recoveryOnly { ok = false }
            if mode == "require-normal", next.recoveryOnly { ok = false }
            version = mode == "wrong-version" ? "99.0.0" : next.version
        }
        return HostWorkerResponse(token: request.token, ok: ok, version: version, message: message)
    }

    private func waitForReply(_ event: HostWorkerNavigationRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            pendingShows[event.token] = continuation
            do { try channel.navigate(event) } catch {
                pendingShows.removeValue(forKey: event.token)?.resume(returning: false)
            }
        }
    }

    private func navigationEvent() -> HostWorkerNavigationRequest? {
        guard let configuration else { return nil }
        var object: [String: Any] = [
            "kind": "navigation", "token": UUID().uuidString,
            "extensionID": configuration.extensionID, "version": configuration.version,
        ]
        if mode == "navigation-wrong-id" { object["extensionID"] = "other" }
        if mode == "navigation-wrong-version" { object["version"] = "99.0.0" }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? JSONDecoder().decode(HostWorkerNavigationRequest.self, from: data)
    }

    private func append(_ request: HostWorkerRequest) {
        guard let record, let data = try? JSONEncoder().encode(request) else { return }
        if let handle = try? FileHandle(forWritingTo: record) {
            handle.seekToEndOfFile()
            handle.write(data + Data([10]))
            try? handle.close()
        } else {
            try? (data + Data([10])).write(to: record)
        }
    }
}
