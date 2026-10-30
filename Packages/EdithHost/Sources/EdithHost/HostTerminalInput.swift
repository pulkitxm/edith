import AppKit
import EdithExtensionUI
import EdithHostCore

struct HostTerminalInputClient {
    let update: @MainActor (HostTerminalUIEvent) async throws -> Bool
    let status: @MainActor () async throws -> HostTerminalUIStatus
}

@MainActor
final class HostTerminalInput {
    private struct Zoom {
        let action: HostTerminalUIAction
        let fallback: @MainActor () -> Void
    }
    private let presentationID: UUID
    private let client: HostTerminalInputClient
    private let window: @MainActor () -> NSWindow?
    private let visible: @MainActor () -> Bool
    private let available: @MainActor () -> Bool
    private let ownsResponder: @MainActor (NSWindow) -> Bool
    private weak var observedWindow: NSWindow?
    private var sequence: UInt64 = 0
    private var pendingState = false
    private var pendingClose = false
    private var zooms: [Zoom] = []
    private var task: Task<Void, Never>?
    private var stopped = false
    private var closing = false
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private(set) var failure: String?
    private(set) var lastEvent: HostTerminalUIEvent?
    private(set) var lastAccepted: Bool?
    private(set) var rejectedEvents = 0

    init(
        presentationID: UUID, client: HostTerminalInputClient,
        window: @escaping @MainActor () -> NSWindow?,
        visible: @escaping @MainActor () -> Bool,
        available: @escaping @MainActor () -> Bool,
        ownsResponder: @escaping @MainActor (NSWindow) -> Bool
    ) {
        self.presentationID = presentationID; self.client = client; self.window = window
        self.visible = visible; self.available = available; self.ownsResponder = ownsResponder
    }

    deinit {
        task?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    static func fontZoom(_ command: WindowKeyCommand) -> HostTerminalUIAction? {
        switch command {
        case .zoomIn: .fontZoomIn
        case .zoomOut: .fontZoomOut
        case .zoomReset: .fontZoomReset
        default: nil
        }
    }

    static func tabAction(characters: String?, modifiers: NSEvent.ModifierFlags)
        -> HostTerminalUIAction?
    {
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        if flags == .command, characters?.lowercased() == "t" { return .newTab }
        guard flags == [.command, .shift] else { return nil }
        switch characters {
        case "w", "W": return .closeTab
        case "]", "}": return .nextTab
        case "[", "{": return .previousTab
        default: return nil
        }
    }

    func consumeTabKey(characters: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let action = Self.tabAction(characters: characters, modifiers: modifiers), !stopped,
            !closing, available(),
            let window = window(), window.isVisible, window.isKeyWindow, NSApp.isActive, visible(),
            ownsResponder(window)
        else { return false }
        guard zooms.count < 8 else { return true }
        zooms.append(Zoom(action: action, fallback: {}))
        drain()
        return true
    }

    func stateChanged() {
        guard !stopped, !closing else { return }
        observe(window())
        pendingState = true
        drain()
    }

    func consumeZoom(_ command: WindowKeyCommand, fallback: @escaping @MainActor () -> Void) -> Bool
    {
        guard let action = Self.fontZoom(command), !stopped, !closing, available(),
            let window = window(), window.isVisible, visible(), ownsResponder(window)
        else { return false }
        guard zooms.count < 8 else { return true }
        zooms.append(Zoom(action: action, fallback: fallback))
        drain()
        return true
    }

    func stop() {
        stopped = true
        pendingState = false; pendingClose = false; zooms.removeAll()
        task?.cancel()
        observe(nil)
    }

    func stopAndWait() async {
        stop()
        await task?.value
    }

    private func drain() {
        guard task == nil, !stopped, available() else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            while !Task.isCancelled, !stopped, available() {
                do {
                    if pendingClose {
                        pendingClose = false
                        let event = try event(action: .windowClosed, closed: true)
                        guard try await deliver(event) else { throw HostWorkerError.rejected }
                    } else if pendingState {
                        pendingState = false
                        let event = try event()
                        guard try await deliver(event) else { throw HostWorkerError.rejected }
                    } else if !zooms.isEmpty {
                        let zoom = zooms.removeFirst()
                        guard let current = window(), current.isVisible, current.isKeyWindow,
                            NSApp.isActive, visible(), ownsResponder(current)
                        else { continue }
                        if [.newTab, .closeTab, .nextTab, .previousTab].contains(zoom.action) {
                            let event = try event(action: zoom.action)
                            guard try await deliver(event) else {
                                throw HostWorkerError.rejected
                            }
                            continue
                        }
                        let status = try await client.status()
                        try Task.checkCancellation()
                        guard !closing, !stopped, available(), window() === current,
                            current.isKeyWindow, current.isVisible, NSApp.isActive, visible(),
                            ownsResponder(current), status.ok,
                            status.presentationID == presentationID
                        else { throw HostWorkerError.rejected }
                        if status.focused {
                            let event = try event(action: zoom.action)
                            guard try await deliver(event) else {
                                throw HostWorkerError.rejected
                            }
                        } else {
                            zoom.fallback()
                        }
                    } else {
                        return
                    }
                    failure = nil
                } catch {
                    guard !stopped, !Task.isCancelled else { return }
                    failure = "The current Terminal scene could not accept input."
                    zooms.removeAll()
                    pendingState = false; pendingClose = false
                    return
                }
            }
        }
    }

    private func deliver(_ event: HostTerminalUIEvent) async throws -> Bool {
        lastEvent = event
        lastAccepted = nil
        let accepted: Bool
        do { accepted = try await client.update(event) } catch {
            lastAccepted = false; rejectedEvents += 1; throw error
        }
        lastAccepted = accepted
        if !accepted { rejectedEvents += 1 }
        return accepted
    }

    func diagnostics() async -> HostCLIJSON {
        var result: [String: HostCLIJSON] = [
            "stopped": .bool(stopped), "available": .bool(available()),
            "rejectedEvents": .integer(Int64(rejectedEvents)),
            "failure": failure.map(HostCLIJSON.string) ?? .null,
        ]
        if let window = window() {
            result["windowKey"] = .bool(window.isKeyWindow)
            result["windowVisible"] = .bool(window.isVisible)
            result["ownsResponder"] = .bool(ownsResponder(window))
            result["firstResponder"] = .string(
                window.firstResponder.map { String(describing: type(of: $0)) } ?? "none")
        }
        result["applicationActive"] = .bool(NSApp.isActive)
        result["pageVisible"] = .bool(visible())
        if let lastEvent {
            result["lastEvent"] = .object([
                "sequence": .integer(Int64(clamping: lastEvent.sequence)),
                "active": .bool(lastEvent.active), "key": .bool(lastEvent.key),
                "visible": .bool(lastEvent.visible),
                "action": lastEvent.action.map { .string($0.rawValue) } ?? .null,
                "accepted": lastAccepted.map(HostCLIJSON.bool) ?? .null,
            ])
        }
        if available(), let status = try? await client.status() {
            result["engineFocused"] = .bool(status.focused)
        }
        return .object(result)
    }

    private func event(action: HostTerminalUIAction? = nil, closed: Bool = false) throws
        -> HostTerminalUIEvent
    {
        guard sequence < UInt64.max else { throw HostWorkerError.rejected }
        sequence += 1
        let current = window()
        return HostTerminalUIEvent(
            presentationID: presentationID, sequence: sequence,
            active: !closed && NSApp.isActive, key: !closed && current?.isKeyWindow == true,
            visible: !closed && visible() && current?.isVisible == true, action: action)
    }

    private func observe(_ next: NSWindow?) {
        guard next !== observedWindow else { return }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        observedWindow = next
        guard let next else { return }
        let center = NotificationCenter.default
        for name in [
            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
            NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: next, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.stateChanged() }
                })
        }
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: NSApp, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.stateChanged() }
                })
        }
        observers.append(
            center.addObserver(forName: NSWindow.willCloseNotification, object: next, queue: .main)
            {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.stopped else { return }
                    self.closing = true; self.pendingState = false; self.zooms.removeAll()
                    self.pendingClose = true
                    self.drain()
                }
            })
    }
}
