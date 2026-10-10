import Foundation
import Observation

enum KeyboardCleaningPhase: String, Codable, Sendable {
    case idle, arming, cleaning
}

enum KeyboardCleaningResult: String, Codable, Sendable {
    case arming, cleaning, inputMonitoringRequired, accessibilityRequired, unavailable
}

struct KeyboardCleaningStatus: Codable, Equatable, Sendable {
    let phase: KeyboardCleaningPhase
    let armingCountdown: Int
    let failsafeRemaining: Int
    let hasInputMonitoring: Bool
    let hasAccessibility: Bool
    let message: String?
}

@MainActor final class KeyboardCleaningTimer {
    private var cancel: (() -> Void)?
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    func invalidate() { cancel?(); cancel = nil }
}

@MainActor struct KeyboardCleaningEnvironment {
    var permissions: () -> (inputMonitoring: Bool, accessibility: Bool)
    var requestInputMonitoring: () -> Void
    var requestAccessibility: () -> Void
    var installTap: () -> Bool
    var removeTap: () -> Void
    var ensureTap: () -> Void
    var showOverlays: (KeyboardCleaning) -> Bool
    var hideOverlays: () -> Void
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> KeyboardCleaningTimer
}

@MainActor @Observable final class KeyboardCleaning {
    private(set) var phase = KeyboardCleaningPhase.idle
    private(set) var armingCountdown = 0
    private(set) var failsafeRemaining = 0
    private(set) var hasInputMonitoring = false
    private(set) var hasAccessibility = false
    private(set) var message: String?
    private(set) var stopped = false
    private let environment: KeyboardCleaningEnvironment
    private var armTimer: KeyboardCleaningTimer?
    private var failsafeTimer: KeyboardCleaningTimer?
    private var healthTimer: KeyboardCleaningTimer?

    init(environment: KeyboardCleaningEnvironment? = nil) {
        self.environment = environment ?? .live
        refreshPermissions()
    }

    var status: KeyboardCleaningStatus {
        .init(
            phase: phase, armingCountdown: armingCountdown, failsafeRemaining: failsafeRemaining,
            hasInputMonitoring: hasInputMonitoring, hasAccessibility: hasAccessibility,
            message: message)
    }

    func refreshPermissions() {
        let permissions = environment.permissions()
        hasInputMonitoring = permissions.inputMonitoring
        hasAccessibility = permissions.accessibility
    }

    @discardableResult func beginCleaning() -> KeyboardCleaningResult {
        guard !stopped else { return .unavailable }
        refreshPermissions()
        guard phase == .idle else { return phase == .arming ? .arming : .cleaning }
        guard hasInputMonitoring else {
            environment.requestInputMonitoring()
            message = "Allow Input Monitoring in System Settings, then try again."
            return .inputMonitoringRequired
        }
        guard hasAccessibility else {
            environment.requestAccessibility()
            message = "Allow Accessibility in System Settings, then try again."
            return .accessibilityRequired
        }
        message = nil
        phase = .arming
        armingCountdown = 3
        guard environment.showOverlays(self) else {
            stopCleaning()
            message = "The keyboard-cleaning overlay could not open."
            return .unavailable
        }
        armTimer = environment.schedule(1) { [weak self] in self?.armTick() }
        return .arming
    }

    func stopCleaning() {
        armTimer?.invalidate(); armTimer = nil
        failsafeTimer?.invalidate(); failsafeTimer = nil
        healthTimer?.invalidate(); healthTimer = nil
        environment.removeTap()
        environment.hideOverlays()
        phase = .idle
        armingCountdown = 0
        failsafeRemaining = 0
    }

    func shutdown() {
        stopped = true
        stopCleaning()
    }

    func execute(_ command: String, payload: Data) throws -> Data {
        guard !stopped else { throw KeyboardCleaningError.unavailable }
        guard payload.isEmpty || payload == Data("{}".utf8) else {
            throw KeyboardCleaningError.invalidRequest
        }
        switch command {
        case "system.cleanKeys":
            let result = beginCleaning()
            return try JSONEncoder().encode(
                KeyboardCleaningResponse(result: result, status: status))
        case "system.stopCleaning": stopCleaning()
        case "system.cleaning.status": refreshPermissions()
        default: throw KeyboardCleaningError.invalidRequest
        }
        return try JSONEncoder().encode(status)
    }

    private func armTick() {
        guard !stopped, phase == .arming else { return }
        armingCountdown -= 1
        guard armingCountdown == 0 else { return }
        armTimer?.invalidate(); armTimer = nil
        guard environment.installTap() else {
            stopCleaning()
            message = "The keyboard could not be locked. Check Input Monitoring and Accessibility."
            return
        }
        phase = .cleaning
        failsafeRemaining = 60
        failsafeTimer = environment.schedule(1) { [weak self] in
            guard let self, !self.stopped, self.phase == .cleaning else { return }
            self.failsafeRemaining -= 1
            if self.failsafeRemaining == 0 { self.stopCleaning() }
        }
        healthTimer = environment.schedule(5) { [weak self] in
            guard let self, !self.stopped, self.phase == .cleaning else { return }
            self.environment.ensureTap()
        }
    }
}

struct KeyboardCleaningResponse: Codable, Equatable, Sendable {
    let result: KeyboardCleaningResult
    let status: KeyboardCleaningStatus
}

enum KeyboardCleaningError: Error { case unavailable, invalidRequest }
