import AVFoundation
import AppKit
import EdithExtensionSupport
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
        try Task.checkCancellation()
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

    func thumbnail(mode: String, id: UInt32) async -> CGImage? {
        let filter: SCContentFilter
        if mode == "displays", let display = displays.first(where: { $0.displayID == id }) {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if mode == "windows", let window = windows.first(where: { $0.windowID == id }) {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            return nil
        }
        let size = Self.thumbnailSize(filter.contentRect.size)
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreShadowsDisplay = true
        let image = try? await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: configuration)
        return Task.isCancelled ? nil : image
    }

    static func thumbnailSize(_ size: CGSize) -> (width: Int, height: Int) {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return (2, 2)
        }
        let scale = min(320 / size.width, 180 / size.height, 1)
        return (max(2, Int(size.width * scale)), max(2, Int(size.height * scale)))
    }
}

actor TimeLapseThumbnailLoader {
    private var tail: Task<CGImage?, Never>?
    private var stopped = false
    private var requests: [UUID: Task<CGImage?, Never>] = [:]

    func shutdown() async {
        stopped = true
        let pending = Array(requests.values)
        for request in pending { request.cancel() }
        for request in pending { _ = await request.value }
        requests.removeAll(); tail = nil
    }

    func load(_ operation: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        guard !stopped, !Task.isCancelled else { return nil }
        let previous = tail
        let token = UUID()
        let task = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return CGImage?.none }
            let image = await operation()
            return Task.isCancelled ? nil : image
        }
        tail = task
        requests[token] = task
        defer { requests[token] = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

struct TimeLapseDisplayChoice: Codable, Identifiable {
    let id: CGDirectDisplayID
    let width: Int
    let height: Int
}

struct TimeLapseWindowChoice: Codable, Identifiable {
    let id: CGWindowID
    let application: String
    let title: String
}
