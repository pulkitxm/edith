import AppKit
import CoreGraphics
import EdithKit
import Foundation

@MainActor
enum BifrostRunningApps {
    static func applications() -> [BifrostRunningApplication] {
        var found: [BifrostRunningApplication] = []
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                let name = application.localizedName, !name.isEmpty,
                let identifier = application.bundleIdentifier
            else { continue }
            found.append(
                BifrostRunningApplication(
                    bundleID: identifier, name: name, path: application.bundleURL?.path))
        }
        return found
    }

    static func application(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }

    nonisolated static func windows() -> [BifrostWindowHandle] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var handles: [BifrostWindowHandle] = []
        for entry in raw {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let owner = entry[kCGWindowOwnerName as String] as? String,
                let number = entry[kCGWindowNumber as String] as? Int,
                let processID = entry[kCGWindowOwnerPID as String] as? Int
            else { continue }
            let title = entry[kCGWindowName as String] as? String ?? ""
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            handles.append(
                BifrostWindowHandle(
                    processID: Int32(processID), ownerName: owner, title: title,
                    windowNumber: number))
        }
        return handles
    }
}
