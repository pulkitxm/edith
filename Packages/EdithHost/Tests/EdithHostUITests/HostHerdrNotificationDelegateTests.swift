import Foundation
import Testing
import UserNotifications
import EdithHostCore

@testable import EdithHost

@Suite @MainActor struct HostHerdrNotificationDelegateTests {
    @Test func actualDelegateRoutesSyntheticRequestWithoutApplicationOrWindows() async throws {
        let delegate = HostApplicationDelegate()
        #expect(
            delegate.responds(
                to: NSSelectorFromString(
                    "userNotificationCenter:didReceiveNotificationResponse:withCompletionHandler:"))
        )
        let request = try HostHerdrNotificationRequest(userInfo: [
            "identifier": "synthetic-event", "title": "Synthetic agent", "body": "Synthetic result",
            "agentID": "synthetic-agent", "hostID": "synthetic-host", "view": "split",
        ])
        var received: HostHerdrNotificationRequest?
        delegate.notificationClick = { received = $0 }
        try await delegate.receiveNotification(request)
        #expect(received == request)
        delegate.notificationClick = nil
        await #expect(throws: HostWorkerError.rejected) {
            try await delegate.receiveNotification(request)
        }
    }
}
