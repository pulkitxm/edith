import AVFoundation
import AppKit
import EdithCore
import ScreenCaptureKit

struct TimeLapseSources {
    let displays: [SCDisplay]
    let windows: [SCWindow]
    let displayChoices: [TimeLapseDisplayChoice]
    let windowChoices: [TimeLapseWindowChoice]
    var displayIDs: Set<CGDirectDisplayID> { Set(displays.map(\.displayID)) }
    var windowIDs: Set<CGWindowID> { Set(windows.map(\.windowID)) }

    static func load() async throws -> Self {
        let content = try await SCShareableContent.excludingDesktopWindows(
            true, onScreenWindowsOnly: true)
        return await Task.detached(priority: .utility) {
            let displays = content.displays.sorted { $0.displayID < $1.displayID }
            let windows = content.windows.filter { $0.frame.width > 1 && $0.frame.height > 1 }
                .sorted { $0.windowID < $1.windowID }
            return Self(
                displays: displays, windows: windows,
                displayChoices: displays.map {
                    .init(id: $0.displayID, width: $0.width, height: $0.height)
                },
                windowChoices: windows.map {
                    .init(
                        id: $0.windowID,
                        application: $0.owningApplication?.applicationName ?? "App",
                        title: $0.title ?? "Untitled window")
                })
        }.value
    }

    func plan(
        mode: String, displays selectedDisplays: Set<CGDirectDisplayID>,
        windows selectedWindows: Set<CGWindowID>, settings: TimeLapseSettings
    ) async throws -> Plan {
        try await Task.detached(priority: .utility) {
            let filters: [SCContentFilter]
            if mode == "displays" {
                let sources = displays.filter { selectedDisplays.contains($0.displayID) }
                guard sources.count == selectedDisplays.count else {
                    throw TimeLapseError.missingSource
                }
                filters = sources.map { SCContentFilter(display: $0, excludingWindows: []) }
            } else {
                let sources = windows.filter { selectedWindows.contains($0.windowID) }
                guard sources.count == selectedWindows.count else {
                    throw TimeLapseError.missingSource
                }
                filters = sources.map { SCContentFilter(desktopIndependentWindow: $0) }
            }
            guard !filters.isEmpty, filters.count <= 16 else {
                throw TimeLapseError.encoding("Choose between one and sixteen displays or windows.")
            }
            let columns = Int(ceil(sqrt(Double(filters.count))))
            let rows = (filters.count + columns - 1) / columns
            let width =
                filters.map { Double($0.contentRect.width) * Double($0.pointPixelScale) }.max()
                ?? 1920
            let height =
                filters.map { Double($0.contentRect.height) * Double($0.pointPixelScale) }.max()
                ?? 1080
            let size = settings.dimensions(
                width: width * Double(columns), height: height * Double(rows))
            guard let display = displays.first else { throw TimeLapseError.missingSource }
            return Plan(
                filters: filters, columns: columns, rows: rows, width: size.width,
                height: size.height,
                audioFilter: SCContentFilter(display: display, excludingWindows: []))
        }.value
    }

    struct Plan {
        let filters: [SCContentFilter]
        let columns: Int
        let rows: Int
        let width: Int
        let height: Int
        let audioFilter: SCContentFilter
    }
}

struct TimeLapseDisplayChoice: Identifiable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
}

struct TimeLapseWindowChoice: Identifiable {
    let id: CGWindowID
    let application: String
    let title: String
}

struct TimeLapseMicrophoneChoice: Identifiable {
    let id: String
    let name: String

    static func load() async -> [Self] {
        await Task.detached(priority: .utility) {
            AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio, position: .unspecified
            ).devices.map {
                Self(id: $0.uniqueID, name: $0.localizedName)
            }
        }.value
    }
}
