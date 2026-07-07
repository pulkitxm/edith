import EdithKit
import Foundation
import Testing

@Suite struct IPCNameTests {
    private let names: [Notification.Name] = [
        IPC.Name.requestUsageRefresh,
        IPC.Name.usageRefreshStarted,
        IPC.Name.usageRefreshFinished,
        IPC.Name.quitMainApp,
        IPC.Name.settingsChanged,
        IPC.Name.requestPermissionsRefresh,
        IPC.Name.grantCalendar,
        IPC.Name.grantNotifications,
        IPC.Name.grantAccessibility,
        IPC.Name.grantInputMonitoring,
        IPC.Name.grantFullDisk,
        IPC.Name.grantScreenRecording,
        IPC.Name.requestTestNotification,
        IPC.Name.clipboardChanged,
        IPC.Name.presenterAutoActiveChanged,
        IPC.Name.musicCommand,
        IPC.Name.musicState,
        IPC.Name.requestMusicState,
        IPC.Name.requestKeyboardClean,
        IPC.Name.openPanel,
    ]

    @Test func namesAreUnique() {
        #expect(Set(names.map(\.rawValue)).count == names.count)
    }

    @Test func namesUseTheAppNamespace() {
        for name in names {
            #expect(name.rawValue.hasPrefix("com.pulkit.edith."))
        }
    }

    @Test func observeReceivesPostedNotification() async {
        let name = Notification.Name("com.pulkit.edith.test.\(UUID().uuidString)")
        let flag = FlagBox()
        let token = IPC.observe(name) { flag.set() }
        defer { IPC.stopObserving(token) }
        IPC.post(name)
        var fired = false
        for _ in 0..<40 {
            if flag.get() {
                fired = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fired)
    }

    @Test func observeWithInfoReceivesUserInfo() async {
        let name = Notification.Name("com.pulkit.edith.test.\(UUID().uuidString)")
        let flag = FlagBox()
        let token = IPC.observe(name) { info in
            if info["value"] as? String == "ping" { flag.set() }
        }
        defer { IPC.stopObserving(token) }
        IPC.post(name, userInfo: ["value": "ping"])
        var fired = false
        for _ in 0..<40 {
            if flag.get() {
                fired = true
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fired)
    }
}

private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func set() {
        lock.lock()
        flag = true
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}
