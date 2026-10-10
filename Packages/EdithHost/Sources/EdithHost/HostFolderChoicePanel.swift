import AppKit
import EdithHostCore

@MainActor
final class HostFolderChoicePanel {
    private let window: @MainActor (HostWorkerNavigationRequest) throws -> NSWindow
    private var panels: [UUID: NSOpenPanel] = [:]

    init(window: @escaping @MainActor (HostWorkerNavigationRequest) throws -> NSWindow) {
        self.window = window
    }

    convenience init(
        manager: HostRemoteSessionManager, presenter: HostRemoteContentPresenter,
        navigation: HostWindowNavigation
    ) {
        self.init { [weak manager, weak presenter, weak navigation] request in
            guard let manager, let presenter, let navigation else { throw HostWorkerError.rejected }
            try manager.validateNavigationOrigin(request)
            guard let id = request.presentationID, let owner = presenter.window(for: id),
                owner.identifier?.rawValue == "EdithMainWindow", owner.isVisible,
                !owner.isMiniaturized,
                navigation.owningWorkspace(for: owner) === owner
            else { throw HostWorkerError.rejected }
            return owner
        }
    }

    func select(_ request: HostWorkerNavigationRequest) async throws -> HostFolderChoiceResult {
        try Task.checkCancellation()
        guard panels.isEmpty, request.folderChoice == true, request.extensionID == "herdr",
            request.location == "settings", request.section == "agentActivity"
        else { throw HostWorkerError.rejected }
        let owner = try window(request)
        guard owner.attachedSheet == nil else { throw HostWorkerError.rejected }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panels[request.token] = panel
        defer { panels.removeValue(forKey: request.token) }
        let response = await withCheckedContinuation { continuation in
            panel.beginSheetModal(for: owner) { continuation.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard try window(request) === owner else { throw HostWorkerError.rejected }
        if response == .cancel { return .init(cancelled: true) }
        guard response == .OK, panel.urls.count == 1, let selected = panel.url, selected.isFileURL
        else {
            throw HostWorkerError.rejected
        }
        let result = HostFolderChoiceResult(selectedPath: selected.path)
        try result.validate()
        return result
    }

    func cancel(_ token: UUID) { panels[token]?.cancel(nil) }
}
