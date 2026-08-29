import Foundation
import Testing

@testable import EdithKit

@Suite struct CaptureToolOperationTests {
    @Test func descriptorsMatchTheCLILeaves() {
        let descriptors = CaptureToolOperation.allCases.map(\.descriptor)
        #expect(
            descriptors.map(\.id.rawValue)
                == [
                    "capture.read", "capture.area", "capture.window", "capture.screen",
                    "capture.library",
                ])
        #expect(
            descriptors.map(\.cli)
                == [
                    ["capture", "read"], ["capture", "area"], ["capture", "window"],
                    ["capture", "screen"], ["capture", "library"],
                ])
        #expect(descriptors.map(\.effect) == Array(repeating: .interactive, count: 5))
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
    }

    @Test func recordingDescriptorsMatchSafeRoutes() {
        let descriptors = ScreenRecordingOperation.allCases.map(\.descriptor)
        #expect(descriptors.map(\.id.rawValue) == [
            "capture.record.area", "capture.record.window", "capture.record.display",
            "capture.record.pause", "capture.record.resume", "capture.record.stop",
            "capture.record.cancel", "capture.record.status", "capture.record.library",
        ])
        #expect(descriptors.first?.cli == ["capture", "record", "area"])
        #expect(descriptors[7].effect == .read)
        #expect(descriptors[6].effect == .destructive)
        for descriptor in descriptors {
            #expect(UserOperationCatalog.descriptor(id: descriptor.id) == descriptor)
            #expect(UserOperationCatalog.descriptor(cli: descriptor.cli) == descriptor)
        }
    }

    @Test func requestsUseDistinctNotifications() {
        var posted: [Notification.Name] = []
        _ = CaptureToolOperationExecution.request(.read) { posted.append($0) }
        _ = CaptureToolOperationExecution.request(.area) { posted.append($0) }
        _ = CaptureToolOperationExecution.request(.window) { posted.append($0) }
        _ = CaptureToolOperationExecution.request(.screen) { posted.append($0) }
        _ = CaptureToolOperationExecution.request(.library) { posted.append($0) }
        #expect(
            posted == [
                IPC.Name.requestScreenRead, IPC.Name.requestCaptureArea,
                IPC.Name.requestCaptureWindow, IPC.Name.requestCaptureScreen,
                IPC.Name.requestCaptureLibrary,
            ])
    }
}
