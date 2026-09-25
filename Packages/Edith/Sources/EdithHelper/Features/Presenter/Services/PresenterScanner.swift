import CoreGraphics
import Darwin
import EdithKit
import Foundation

struct PresenterScan: Equatable, Sendable {
    let windowReason: String?
    let recordingHit: Bool
}

struct PresenterWindowSource: Sendable {
    var windows: @Sendable () -> [PresenterWindowInfo]
    var titlesAvailable: @Sendable () -> Bool
    var recording: @Sendable () -> Bool

    static let live = PresenterWindowSource(
        windows: { onScreenWindows() },
        titlesAvailable: { CGPreflightScreenCaptureAccess() },
        recording: {
            let wanted =
                SharedDefaults.store.object(forKey: AppStorageKeys.Presenter.detectRecording)
                as? Bool ?? true
            return wanted && isProcessRunning(named: "screencapture")
        })

    static func onScreenWindows() -> [PresenterWindowInfo] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let owner = info[kCGWindowOwnerName as String] as? String else { return nil }
            let bounds = info[kCGWindowBounds as String] as? [String: Any] ?? [:]
            return PresenterWindowInfo(
                ownerName: owner, title: info[kCGWindowName as String] as? String ?? "",
                width: bounds["Width"] as? Double ?? 0, height: bounds["Height"] as? Double ?? 0,
                layer: info[kCGWindowLayer as String] as? Int ?? 0)
        }
    }

    static func isProcessRunning(named target: String) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return false }
        size += size / 8
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 4, &buffer, &size, nil, 0) == 0 else { return false }
        let stride = MemoryLayout<kinfo_proc>.stride
        let count = size / stride
        let name = Array(target.utf8)
        let commLength = MemoryLayout.size(ofValue: kinfo_proc().kp_proc.p_comm)
        guard name.count < commLength, !name.contains(0),
            let commOffset = MemoryLayout<kinfo_proc>.offset(of: \kinfo_proc.kp_proc.p_comm)
        else { return false }
        return buffer.withUnsafeBytes { raw in
            for index in 0..<count {
                let start = index * stride + commOffset
                if raw[start + name.count] == 0,
                    raw[start..<start + name.count].elementsEqual(name)
                {
                    return true
                }
            }
            return false
        }
    }
}

final class PresenterScanner: @unchecked Sendable {
    static let titlesLifetime: TimeInterval = 30

    let jev: PresenterJevCheck
    private let source: PresenterWindowSource
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var titles: (available: Bool, at: Date)?

    init(
        source: PresenterWindowSource = .live, jev: PresenterJevCheck = .live,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.source = source
        self.jev = jev
        self.now = now
    }

    func scan() -> PresenterScan {
        let titlesAvailable = titlesAvailable()
        let windows = source.windows()
        let reason =
            PresenterRules.firstMatch(in: windows, titlesAvailable: titlesAvailable)
            ?? (titlesAvailable ? jev.reason(for: windows) : nil)
        return PresenterScan(windowReason: reason, recordingHit: source.recording())
    }

    private func titlesAvailable() -> Bool {
        let moment = now()
        if let cached = lock.withLock({ titles }),
            moment.timeIntervalSince(cached.at) < Self.titlesLifetime
        {
            return cached.available
        }
        let available = source.titlesAvailable()
        lock.withLock { titles = (available, moment) }
        return available
    }
}
