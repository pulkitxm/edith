import EdithExtensionSupport
import Foundation
import Observation

public struct HostSurfaceEditorRequest: Equatable, Sendable {
    public let token: UUID
    public let target: SurfaceTarget
    public let tileID: String?
}

@MainActor @Observable
public final class HostSurfaceNavigation {
    public private(set) var editorRequest: HostSurfaceEditorRequest?
    @ObservationIgnored private let context: SurfaceHostContext
    @ObservationIgnored private let channel: ExtensionSharedState
    @ObservationIgnored private var lastToken: String?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private nonisolated(unsafe) var observer: NSObjectProtocol?

    public init(context: SurfaceHostContext) {
        self.context = context
        channel = context.sharedState
        lastToken = context.sharedState.values(for: "notchShelf")["surface.openEditorToken"]
        observer = context.sharedState.observe { [weak self] owner in
            guard owner == "notchShelf" else { return }
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit { channel.stopObserving(observer) }

    public func refresh() {
        guard !stopped, context.activeIDs.contains("notchShelf") else { return }
        let values = context.sharedState.values(for: "notchShelf")
        guard values["surface.openEditor"] == "notch",
            let raw = values["surface.openEditorToken"], raw != lastToken,
            let token = UUID(uuidString: raw)
        else { return }
        let tileID = values["surface.openEditorTileID"]
        guard tileID.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) ?? true
        else { return }
        lastToken = raw
        editorRequest = HostSurfaceEditorRequest(token: token, target: .notch, tileID: tileID)
    }

    public func shutdown() {
        stopped = true
        channel.stopObserving(observer); observer = nil; editorRequest = nil
    }
}
