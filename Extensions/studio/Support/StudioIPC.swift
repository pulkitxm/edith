import Foundation

enum IPC {
    enum Name {
        static let requestVideoEditorOpen = Notification.Name("studio.requestVideoEditorOpen")
        static let videoEditorOpenResult = Notification.Name("studio.videoEditorOpenResult")
        static let videoProjectLibraryChanged = Notification.Name(
            "studio.videoProjectLibraryChanged")
        static let studioMediaLibraryChanged = Notification.Name("studio.mediaLibraryChanged")
        static let studioWorkflowsChanged = Notification.Name("studio.workflowsChanged")
        static let requestStudioCancel = Notification.Name("studio.requestCancel")
        static let studioJobResult = Notification.Name("studio.jobResult")
        static let requestStudioRecord = Notification.Name("studio.requestRecord")
        static let studioRecordResult = Notification.Name("studio.recordResult")
    }

    static func post(_ name: Notification.Name, userInfo: [String: Any]? = nil) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
    }

    static func observe(
        _ name: Notification.Name, info block: @escaping ([AnyHashable: Any]) -> Void
    ) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
            block(note.userInfo ?? [:])
        }
    }

    static func stopObserving(_ token: NSObjectProtocol) {
        NotificationCenter.default.removeObserver(token)
    }
}
