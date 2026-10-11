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
        var expires = ContinuousClock.now.advanced(by: .seconds(10))
        var discarded = false
    }
    private var jobs: [UUID: Job] = [:]
    private var retirements: [UUID: Task<Void, Never>] = [:]
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
                guard !Task.isCancelled, let owner else { return }
                do {
                    let result = try await owner.execute("homebrew." + operation, payload: encoded)
                    guard !Task.isCancelled, let self, !stopped, jobs[token]?.discarded == false
                    else { return }
                    jobs[token]?.payload = result; jobs[token]?.complete = true
                } catch {
                    guard let self, !stopped, jobs[token]?.discarded == false else { return }
                    jobs[token]?.error = error.localizedDescription; jobs[token]?.complete = true
                }
            }
            renew(token)
            return try JSONEncoder().encode(
                HomebrewUIJobReply(token: token, complete: false, payload: nil, error: nil))
        }
        guard Set(values.keys) == ["token"],
            let token = values["token"].flatMap(UUID.init(uuidString:)), let job = jobs[token],
            !job.discarded
        else { throw ExtensionPeerError.invalidRequest }
        if command == "homebrew.ui.cancel" {
            retire(token)
            return Data("{}".utf8)
        }
        guard command == "homebrew.ui.poll" else { throw ExtensionPeerError.invalidRequest }
        let reply = HomebrewUIJobReply(
            token: token, complete: job.complete, payload: job.payload, error: job.error)
        if job.complete {
            retire(token)
        } else {
            renew(token)
        }
        return try JSONEncoder().encode(reply)
    }
    private func renew(_ token: UUID) {
        jobs[token]?.expires = .now.advanced(by: .seconds(10))
        guard jobs[token]?.lease == nil else { return }
        jobs[token]?.lease = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let job = jobs[token], !job.discarded else { return }
                let remaining = ContinuousClock.now.duration(to: job.expires)
                if remaining <= .zero { retire(token); return }
                do { try await Task.sleep(for: remaining) } catch { return }
            }
        }
    }

    private func retire(_ token: UUID) {
        guard let job = jobs[token], !job.discarded else { return }
        jobs[token]?.discarded = true
        job.task?.cancel()
        job.lease?.cancel()
        retirements[token] = Task { [weak self] in
            await job.task?.value
            await job.lease?.value
            self?.jobs.removeValue(forKey: token)
            self?.retirements.removeValue(forKey: token)
        }
    }

    func shutdown() {
        stopped = true
        for token in Array(jobs.keys) { retire(token) }
    }

    func shutdownAndWait() async {
        shutdown()
        let pending = Array(retirements.values)
        for task in pending { await task.value }
    }
}
