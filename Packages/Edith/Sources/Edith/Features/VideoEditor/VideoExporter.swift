import AppKit
import Observation
import UserNotifications

@MainActor
@Observable
final class VideoExporter {
    enum Phase: Equatable {
        case exporting
        case finished
        case failed(String)
    }

    struct Job: Identifiable {
        let id = UUID()
        let destination: URL
        let startedAt = Date()
        var progress = 0.0
        var phase = Phase.exporting

        var secondsRemaining: Double? {
            let elapsed = Date().timeIntervalSince(startedAt)
            guard phase == .exporting, progress > 0.02, elapsed > 2 else { return nil }
            return elapsed * (1 - progress) / progress
        }
    }

    typealias Work = (@escaping @Sendable (Double) -> Void) async throws -> Void

    static let shared = VideoExporter(onComplete: VideoExportBackground.complete)

    private(set) var job: Job?
    private var task: Task<Void, Never>?
    private let onComplete: (Job?) async -> Void

    init(onComplete: @escaping (Job?) async -> Void = { _ in }) {
        self.onComplete = onComplete
    }

    var isExporting: Bool { job?.phase == .exporting }

    func start(to destination: URL, work: @escaping Work) {
        guard !isExporting else { return }
        task?.cancel()
        let started = Job(destination: destination)
        job = started
        task = Task {
            let outcome: Phase?
            do {
                try await work { [weak self] value in
                    Task { @MainActor in self?.report(value, for: started.id) }
                }
                outcome = .finished
            } catch is CancellationError {
                outcome = nil
            } catch {
                outcome = Task.isCancelled ? nil : .failed(error.localizedDescription)
            }
            await finish(started.id, outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func clear() {
        guard !isExporting else { return }
        job = nil
    }

    private func report(_ progress: Double, for id: UUID) {
        guard var current = job, current.id == id, current.phase == .exporting else { return }
        current.progress = min(1, max(current.progress, progress))
        job = current
    }

    private func finish(_ id: UUID, _ outcome: Phase?) async {
        guard job?.id == id else { return }
        task = nil
        if let outcome {
            job?.phase = outcome
            if outcome == .finished { job?.progress = 1 }
        } else {
            job = nil
        }
        await onComplete(job)
    }
}

@MainActor
enum VideoExportBackground {
    private static var quitsWhenDone = false

    static func keepsAppOpenAfterLastWindowClosed() -> Bool {
        guard VideoExporter.shared.isExporting else { return false }
        quitsWhenDone = true
        return true
    }

    static func defersQuit(_ application: NSApplication) -> Bool {
        guard VideoExporter.shared.isExporting else { return false }
        quitsWhenDone = true
        application.hide(nil)
        return true
    }

    static func userReturned() {
        quitsWhenDone = false
    }

    static func complete(_ job: VideoExporter.Job?) async {
        if let job, quitsWhenDone || !NSApp.isActive { await notify(job) }
        guard quitsWhenDone else { return }
        quitsWhenDone = false
        let windowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if NSApp.isHidden || !windowOpen { NSApp.terminate(nil) }
    }

    private static func notify(_ job: VideoExporter.Job) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = job.phase == .finished ? "Export finished" : "Export failed"
        if case .failed(let message) = job.phase {
            content.body = "\(job.destination.lastPathComponent): \(message)"
        } else {
            content.body = job.destination.lastPathComponent
        }
        try? await center.add(
            UNNotificationRequest(
                identifier: "video-export-\(job.id)", content: content, trigger: nil))
    }
}
