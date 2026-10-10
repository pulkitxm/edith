import EdithExtensionSupport
import Foundation

struct HomebrewUIJobReply: Codable {
    let token: UUID
    let complete: Bool
    let payload: Data?
    let error: String?
}
@MainActor final class HomebrewUIJobs {
    private struct Job {
        var task: Task<Void, Never>?
        var payload: Data?
        var error: String?
        var complete = false
        var lease: Task<Void, Never>?
    }
    private var jobs: [UUID: Job] = [:]
    private var stopped = false
    func execute(_ command: String, payload: Data, owner: HomebrewEngineCommands) throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let values = try JSONDecoder().decode([String: String].self, from: payload)
        if command == "homebrew.ui.begin" {
            guard jobs.count < 8, let operation = values["operation"],
                ["status", "list", "search", "install", "upgrade", "uninstall"].contains(operation)
            else { throw ExtensionPeerError.invalidRequest }
            var input = values; input.removeValue(forKey: "operation")
            let encoded = try JSONEncoder().encode(input), token = UUID()
            jobs[token] = Job()
            jobs[token]?.task = Task { [weak self, weak owner] in
                guard let owner else { return }
                do {
                    let result = try await owner.execute("homebrew." + operation, payload: encoded)
                    guard !Task.isCancelled, let self, !stopped, jobs[token] != nil else { return }
                    jobs[token]?.payload = result; jobs[token]?.complete = true
                } catch {
                    guard let self, !stopped, jobs[token] != nil else { return }
                    jobs[token]?.error = error.localizedDescription; jobs[token]?.complete = true
                }
            }
            renew(token)
            return try JSONEncoder().encode(
                HomebrewUIJobReply(token: token, complete: false, payload: nil, error: nil))
        }
        guard Set(values.keys) == ["token"],
            let token = values["token"].flatMap(UUID.init(uuidString:)), let job = jobs[token]
        else { throw ExtensionPeerError.invalidRequest }
        if command == "homebrew.ui.cancel" {
            job.task?.cancel(); job.lease?.cancel(); jobs.removeValue(forKey: token)
            return Data("{}".utf8)
        }
        guard command == "homebrew.ui.poll" else { throw ExtensionPeerError.invalidRequest }
        let reply = HomebrewUIJobReply(
            token: token, complete: job.complete, payload: job.payload, error: job.error)
        if job.complete {
            job.lease?.cancel(); jobs.removeValue(forKey: token)
        } else {
            renew(token)
        }
        return try JSONEncoder().encode(reply)
    }
    private func renew(_ token: UUID) {
        jobs[token]?.lease?.cancel()
        jobs[token]?.lease = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.jobs[token]?.task?.cancel(); self?.jobs.removeValue(forKey: token)
        }
    }
    func shutdown() {
        stopped = true
        for job in jobs.values { job.task?.cancel(); job.lease?.cancel() }
    }
    func shutdownAndWait() async {
        shutdown()
        let pending = Array(jobs.values)
        jobs.removeAll()
        for job in pending { job.task?.cancel(); job.lease?.cancel() }
        for job in pending { await job.task?.value }
    }
}
