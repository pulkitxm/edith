import EdithExtensionSupport
import Foundation

extension NotchShelfController {
    func execute(_ command: String, payload: Data) async throws -> Data {
        switch command {
        case "surface.snapshot":
            let request = try SurfaceSnapshotRequest.decode(payload, providerID: "notchShelf")
            return try snapshot(request).encoded()
        case "surface.perform":
            let request = try SurfaceActionRequest.decode(payload, providerID: "notchShelf")
            let current = snapshot(request.snapshot)
            guard current.actions.contains(where: { $0.id == request.actionID }) else {
                throw ExtensionPeerError.invalidRequest
            }
            if request.actionID == "customize" {
                openCustomization()
            } else {
                throw ExtensionPeerError.invalidRequest
            }
            return try snapshot(request.snapshot).encoded()
        case "notch.browser":
            guard let browser else { throw ExtensionPeerError.unavailable }
            let request = try JSONDecoder().decode(NotchBrowserRequest.self, from: payload)
            return try JSONEncoder().encode(browser.perform(request))
        default: throw ExtensionPeerError.unavailable
        }
    }

    private func snapshot(_ request: SurfaceSnapshotRequest) -> SurfaceSnapshot {
        let hidden = privacy.hides(.ability("notchShelf"))
        return SurfaceSnapshot(
            providerID: "notchShelf",
            metrics: [.init("files", "Files", String(items.count))],
            rows: hidden
                ? []
                : items.prefix(request.tile.itemLimit).map {
                    .init($0.id.uuidString, title: $0.name, icon: "doc.fill")
                },
            actions: request.tile.showActions
                ? [.init("customize", "Customize", "slider.horizontal.3")] : [],
            message: hidden ? "Hidden while presenting" : nil
        )
    }
}
