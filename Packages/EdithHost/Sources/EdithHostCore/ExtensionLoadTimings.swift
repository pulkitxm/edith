import AppKit
import Darwin
import Foundation
import os

@MainActor
public final class ExtensionLoadTimings {
    public enum Phase: String, CaseIterable, Sendable {
        case verify, start, presentation, firstFrame
    }

    public struct Entry: Equatable, Sendable {
        public var milliseconds: [Phase: Double] = [:]
        public var readyAfterLaunch: Double?
        public var presentedAfterLaunch: Double?
    }

    public static let shared = ExtensionLoadTimings()

    public private(set) var entries: [String: [String: Entry]] = [:]
    private let logger = Logger(subsystem: "com.pulkit.edith", category: "extension-load")
    private let launch: Date

    public init(launch: Date = ExtensionLoadTimings.processStart()) {
        self.launch = launch
    }

    public func measure<T>(
        id: String, role: String, _ phase: Phase, _ body: () throws -> T
    ) rethrows -> T {
        let started = ContinuousClock.now
        let value = try body()
        record(id: id, role: role, phase, elapsed: ContinuousClock.now - started)
        return value
    }

    public func record(id: String, role: String, _ phase: Phase, elapsed: Duration) {
        let milliseconds = Self.milliseconds(elapsed)
        var entry = entries[id, default: [:]][role, default: Entry()]
        let first = entry.milliseconds[phase] == nil
        entry.milliseconds[phase] = milliseconds
        let sinceLaunch = Date().timeIntervalSince(launch) * 1000
        if phase == .start { entry.readyAfterLaunch = sinceLaunch }
        if phase == .firstFrame, first { entry.presentedAfterLaunch = sinceLaunch }
        entries[id, default: [:]][role] = entry
        let rounded = String(format: "%.1f", milliseconds)
        logger.info(
            "\(id, privacy: .public).\(role, privacy: .public) \(phase.rawValue, privacy: .public) \(rounded, privacy: .public)ms"
        )
    }

    public func reset(id: String) { entries[id] = nil }

    public func observeFirstFrame(
        id: String, role: String, view: NSView, started: ContinuousClock.Instant,
        attempts: Int = 600
    ) {
        guard entries[id]?[role]?.milliseconds[.firstFrame] == nil else { return }
        if view.window != nil {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.entries[id]?[role]?.milliseconds[.firstFrame] == nil else { return }
                    self.record(
                        id: id, role: role, .firstFrame, elapsed: ContinuousClock.now - started)
                }
            }
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak view] in
                MainActor.assumeIsolated {
                    guard let view else { return }
                    self.observeFirstFrame(
                        id: id, role: role, view: view, started: started, attempts: attempts - 1)
                }
            }
        }
    }

    public func json(id: String) -> [String: Any] {
        guard let roles = entries[id] else { return [:] }
        return roles.mapValues { entry in
            var values: [String: Any] = [:]
            for (phase, value) in entry.milliseconds {
                values[phase.rawValue + "Ms"] = Self.rounded(value)
            }
            if let ready = entry.readyAfterLaunch {
                values["readyAfterLaunchMs"] = Self.rounded(ready)
            }
            if let presented = entry.presentedAfterLaunch {
                values["presentedAfterLaunchMs"] = Self.rounded(presented)
            }
            return values
        }
    }

    public nonisolated static func processStart() -> Date {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(
            timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec)
                / 1_000_000)
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    private static func rounded(_ value: Double) -> NSDecimalNumber {
        NSDecimalNumber(
            string: String(format: "%.1f", value), locale: Locale(identifier: "en_US_POSIX"))
    }
}
