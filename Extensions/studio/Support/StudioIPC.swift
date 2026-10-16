import Foundation

enum IPC {
    enum Name {
        static let videoProjectLibraryChanged = Notification.Name(
            "studio.videoProjectLibraryChanged")
        static let studioMediaLibraryChanged = Notification.Name("studio.mediaLibraryChanged")
        static let studioWorkflowsChanged = Notification.Name("studio.workflowsChanged")
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
