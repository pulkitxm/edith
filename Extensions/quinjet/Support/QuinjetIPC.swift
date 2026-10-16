import Foundation

enum QuinjetIPC {
    enum Name {
        static let requestQuinjetSessionOperation = "quinjet.session.request"
        static let quinjetSessionOperationResult = "quinjet.session.result"
    }
    static func observe(_ name: String, info: @escaping ([AnyHashable: Any]) -> Void)
        -> NSObjectProtocol
    {
        NotificationCenter.default.addObserver(forName: .init(name), object: nil, queue: .main) {
            notification in
            info(notification.userInfo ?? [:])
        }
    }
    static func post(_ name: String, userInfo: [AnyHashable: Any]) {
        NotificationCenter.default.post(name: .init(name), object: nil, userInfo: userInfo)
    }
}
