import AppKit
import EdithKit
import SwiftUI

@MainActor
enum CLIWindowBridge {
    private static var revealObserver: NSObjectProtocol?
    private static var snapshotObserver: NSObjectProtocol?

    static func install() {
        guard revealObserver == nil else { return }
        revealObserver = IPC.observe(IPC.Name.requestReveal) { info in
            MainActor.assumeIsolated { reveal(info) }
        }
        snapshotObserver = IPC.observe(IPC.Name.requestWindowSnapshot) { info in
            MainActor.assumeIsolated { snapshot(info) }
        }
    }

    private static func fail(_ message: String) {
        IPC.post(IPC.Name.revealResult, userInfo: ["ok": false, "error": message])
    }

    private static func reveal(_ info: [AnyHashable: Any]) {
        let sectionRaw = info["section"] as? String ?? ""
        guard !sectionRaw.isEmpty else {
            MainWindow.open()
            let current =
                SharedDefaults.store.string(forKey: AppStorageKeys.General.mainWindowSection)
                ?? MainDestination.home.rawValue
            IPC.post(IPC.Name.revealResult, userInfo: ["ok": true, "section": current])
            return
        }
        guard let section = MainDestination(rawValue: sectionRaw) else {
            fail(
                "no section named \(sectionRaw); sections: "
                    + MainDestination.allCases.map(\.rawValue).joined(separator: ", "))
            return
        }
        let tabRaw = (info["tab"] as? String) ?? ""
        var resolvedTab = ""
        if !tabRaw.isEmpty {
            switch section {
            case .companion:
                guard let tab = CompanionTab(rawValue: tabRaw) else {
                    fail(
                        "companion has no tab named \(tabRaw); tabs: "
                            + CompanionTab.allCases.map(\.rawValue).joined(separator: ", "))
                    return
                }
                SharedDefaults.store.set(tab.rawValue, forKey: AppStorageKeys.Companion.tab)
                resolvedTab = tab.rawValue
            case .settings:
                guard let tab = SettingsPane.Tab(rawValue: tabRaw) else {
                    fail(
                        "settings has no tab named \(tabRaw); tabs: "
                            + SettingsPane.Tab.allCases.map(\.rawValue).joined(separator: ", "))
                    return
                }
                SharedDefaults.store.set(tab.rawValue, forKey: AppStorageKeys.General.settingsTab)
                resolvedTab = tab.rawValue
            default:
                fail("\(section.rawValue) has no tabs; drop --tab")
                return
            }
        }
        SharedDefaults.store.set(
            section.rawValue, forKey: AppStorageKeys.General.mainWindowSection)
        MainWindow.open()
        var payload: [String: Any] = ["ok": true, "section": section.rawValue]
        if !resolvedTab.isEmpty { payload["tab"] = resolvedTab }
        IPC.post(IPC.Name.revealResult, userInfo: payload)
    }

    private static func snapshot(_ info: [AnyHashable: Any]) {
        let requested = (info["dir"] as? String) ?? ""
        let directory = URL(
            fileURLWithPath: requested.isEmpty ? "/tmp/edith-snapshots" : requested,
            isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        } catch {
            IPC.post(
                IPC.Name.windowSnapshotResult,
                userInfo: [
                    "ok": false,
                    "error": "could not create \(directory.path): "
                        + error.localizedDescription,
                ])
            return
        }
        var files: [String] = []
        var used: [String: Int] = [:]
        for window in NSApp.windows where window.isVisible {
            guard let image = render(window) else { continue }
            let base = slug(window.title.isEmpty ? "window" : window.title)
            let count = (used[base] ?? 0) + 1
            used[base] = count
            let name = count == 1 ? "\(base).png" : "\(base)-\(count).png"
            let url = directory.appendingPathComponent(name)
            do {
                try image.write(to: url)
                files.append(url.path)
            } catch {
                continue
            }
        }
        guard !files.isEmpty else {
            IPC.post(
                IPC.Name.windowSnapshotResult,
                userInfo: ["ok": false, "error": "no visible window rendered"])
            return
        }
        IPC.post(
            IPC.Name.windowSnapshotResult,
            userInfo: ["ok": true, "files": files.joined(separator: "\n")])
    }

    private static func render(_ window: NSWindow) -> Data? {
        window.displayIfNeeded()
        guard let contentView = window.contentView else { return nil }
        let frameView = contentView.superview ?? contentView
        let bounds = frameView.bounds
        guard bounds.width > 40, bounds.height > 40,
            let bitmap = frameView.bitmapImageRepForCachingDisplay(in: bounds)
        else { return nil }
        frameView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let mapped = lowered.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "window" : collapsed
    }
}
