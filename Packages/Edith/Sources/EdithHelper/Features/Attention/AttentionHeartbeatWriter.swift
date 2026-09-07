import AppKit
import ApplicationServices
import EdithKit
import Foundation

struct AttentionHeartbeatSample: Sendable {
    var event: AttentionEvent
    let processID: pid_t
    let captureWindowTitle: Bool
}

@MainActor
final class AttentionHeartbeatWriter {
    typealias Prepare = @Sendable (AttentionHeartbeatSample) async -> AttentionEvent
    typealias Deliver = @Sendable (AttentionDeliveryRequest) async throws -> Void

    private let spool: AttentionDeliverySpool
    private let prepare: Prepare
    private let deliver: Deliver
    private let retryDelay: Duration
    private let maximumPending: Int
    private var samples: [AttentionHeartbeatSample] = []
    private var unsaved: [AttentionEvent] = []
    private var preparingCount = 0
    private var overflowCount = 0
    private var overflowDuration: TimeInterval = 0
    private(set) var storageFailed = false
    private var stopping = false
    private var waitingToRetry = false
    nonisolated(unsafe) private var worker: Task<Void, Never>?
    nonisolated(unsafe) private var deliveryTask: Task<Void, Error>?
    nonisolated(unsafe) private var retryTask: Task<Void, Never>?

    init(
        spool: AttentionDeliverySpool = AttentionDeliverySpool(),
        maximumPending: Int = 32, retryDelay: Duration = .seconds(30),
        prepare: @escaping Prepare = { await AttentionHeartbeatCapture.prepare($0) },
        deliver: @escaping Deliver = { try await AttentionDeliveryClient.deliver($0) }
    ) {
        self.spool = spool
        self.maximumPending = max(1, maximumPending)
        self.retryDelay = retryDelay
        self.prepare = prepare
        self.deliver = deliver
        kick()
    }

    deinit {
        worker?.cancel()
        deliveryTask?.cancel()
        retryTask?.cancel()
    }

    var queuedSampleCount: Int { samples.count + unsaved.count + preparingCount }
    var isStopped: Bool { stopping && worker == nil && deliveryTask == nil && retryTask == nil }

    func submit(_ sample: AttentionHeartbeatSample) {
        guard !stopping else { return }
        guard queuedSampleCount < maximumPending else {
            overflowCount += min(1, Int.max - overflowCount)
            overflowDuration = min(1e15, overflowDuration + sample.event.duration)
            if overflowCount == 1 {
                NSLog("Attention capture queue is full. New samples were not retained.")
            }
            return
        }
        samples.append(sample)
        kick()
    }

    func health() async throws -> AttentionDeliveryHealth {
        try await spool.health()
    }

    func flush() async {
        kick()
        await worker?.value
    }

    func stop() async {
        stopping = true
        retryTask?.cancel()
        let retry = retryTask
        retryTask = nil
        deliveryTask?.cancel()
        kick()
        await worker?.value
        await retry?.value
    }

    private func kick() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.run()
            guard !Task.isCancelled else { return }
            self?.worker = nil
            self?.scheduleRetry()
        }
    }

    private func run() async {
        while !Task.isCancelled {
            if !samples.isEmpty {
                let pending = samples
                samples.removeAll()
                preparingCount = pending.count
                for sample in pending {
                    if stopping {
                        unsaved.append(sample.event)
                    } else {
                        unsaved.append(await prepare(sample))
                    }
                    preparingCount -= 1
                }
            }
            do {
                if !unsaved.isEmpty {
                    _ = try await spool.append(unsaved)
                    unsaved.removeAll()
                }
                if overflowCount > 0 {
                    let count = overflowCount
                    let duration = overflowDuration
                    try await spool.recordOverflow(events: count, duration: duration)
                    overflowCount -= count
                    overflowDuration = max(0, overflowDuration - duration)
                }
                storageFailed = false
            } catch {
                if !storageFailed {
                    NSLog(
                        "Attention delivery storage is unavailable. Queued samples remain pending.")
                }
                storageFailed = true
                waitingToRetry = true
                return
            }
            if !samples.isEmpty { continue }
            guard !stopping, !waitingToRetry else { return }
            do {
                guard let request = try await spool.first() else { return }
                let send = deliver
                let task = Task { try await send(request) }
                deliveryTask = task
                do {
                    try await task.value
                    deliveryTask = nil
                    try await spool.acknowledge(request)
                } catch {
                    deliveryTask = nil
                    if !stopping { try? await spool.failedDelivery() }
                    waitingToRetry = true
                }
            } catch {
                storageFailed = true
                waitingToRetry = true
            }
        }
    }

    private func scheduleRetry() {
        guard !stopping, waitingToRetry else { return }
        guard retryTask == nil else { return }
        let delay = retryDelay
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            retryTask = nil
            waitingToRetry = false
            kick()
        }
    }
}

enum AttentionHeartbeatCapture {
    static func prepare(_ sample: AttentionHeartbeatSample) async -> AttentionEvent {
        guard sample.captureWindowTitle else { return sample.event }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var event = sample.event
                event.windowTitle = focusedWindowTitle(pid: sample.processID)
                continuation.resume(returning: event)
            }
        }
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var windowValue: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXFocusedWindowAttribute as CFString, &windowValue) == .success,
            let window = windowValue,
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var title: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXTitleAttribute as CFString, &title) == .success
        else { return nil }
        return (title as? String).map { String($0.prefix(500)) }
    }
}
