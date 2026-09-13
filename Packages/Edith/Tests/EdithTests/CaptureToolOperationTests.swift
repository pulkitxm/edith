import Foundation
import Testing

@testable import EdithKit

@Suite struct CaptureToolOperationTests {
    @Test func descriptorsMatchTheCLILeaves() {
        let descriptors = CaptureToolOperation.allCases.map(\.descriptor)
        #expect(descriptors.map(\.id.rawValue) == ["capture.read", "capture.screenshot"])
        #expect(descriptors.map(\.cli) == [["capture", "read"], ["capture", "screenshot"]])
        #expect(descriptors.map(\.effect) == [.interactive, .interactive])
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
    }

    @Test func requestsUseDistinctNotifications() {
        var posted: [Notification.Name] = []
        _ = CaptureToolOperationExecution.request(.read) { posted.append($0) }
        _ = CaptureToolOperationExecution.request(.screenshot) { posted.append($0) }
        #expect(posted == [IPC.Name.requestScreenRead, IPC.Name.requestScreenshot])
    }
}
