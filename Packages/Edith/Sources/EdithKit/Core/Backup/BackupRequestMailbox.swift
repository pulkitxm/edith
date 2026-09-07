import Foundation

struct BackupRequests: Sendable {
    var settings = false
    var usage = false
    var limits = false
    var clipboard = false
    var restores: Set<SettingsBackupDataClass> = []
}

final class BackupRequestMailbox: @unchecked Sendable {
    enum Signal: Sendable {
        case settings, usage, limits, clipboard
        case restore(SettingsBackupDataClass)
    }

    let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var pending = BackupRequests()
    private var closed = false

    init() {
        (stream, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ signal: Signal) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        switch signal {
        case .settings: pending.settings = true
        case .usage: pending.usage = true
        case .limits: pending.limits = true
        case .clipboard: pending.clipboard = true
        case .restore(let dataClass): pending.restores.insert(dataClass)
        }
        continuation.yield(())
    }

    func take() -> BackupRequests {
        lock.lock()
        defer { lock.unlock() }
        let requests = pending
        pending = BackupRequests()
        return requests
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        pending = BackupRequests()
        continuation.finish()
    }
}
