import EdithExtensionUI
import EdithExtensionSupport
import Foundation

@MainActor
public enum CompanionBackgroundOperation {
    public static let outboxChanged = "companionOutboxChanged"
    static weak var monitor: CompanionMonitor?

    public static func requestRefresh() async throws {
        guard let monitor else { throw ExtensionPeerError.unavailable }
        _ = await monitor.refresh()
    }
}
