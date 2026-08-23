import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct AppRuntimeOperationTests {
    @Test func descriptorsAreUniqueAndRegistered() {
        let descriptors = AppRuntimeOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
    }

    @Test func onlyRemoteOperationsCarryNotifications() {
        for operation in AppRuntimeOperation.allCases {
            #expect((operation.notification != nil) == (operation.owner != .local))
        }
    }

    @Test func everyDescriptorNamesARealCLILeaf() {
        for descriptor in AppRuntimeOperation.allCases.map(\.descriptor) {
            let node = descriptor.cli.reduce(Optional(CommandTree.root)) { node, component in
                node?.child(component)
            }
            #expect(
                node?.children.isEmpty == true,
                "missing ed \(descriptor.cli.joined(separator: " "))")
        }
    }

    @Test func destructiveOperationsRequirePreview() {
        let destructive = AppRuntimeOperation.allCases.filter {
            $0.descriptor.effect == .destructive
        }
        #expect(destructive.map(\.descriptor).allSatisfy { $0.requiresPreview })
    }

    @Test func requestsUseTheTypedOperationAndPayload() {
        final class Capture {
            var operation: AppRuntimeOperation?
            var notification: Notification.Name?
            var value: String?
        }
        let capture = Capture()
        let center = AppRuntimeCenter(
            post: { name, info in
                capture.notification = name
                capture.value = info?["section"] as? String
            },
            willPerform: { capture.operation = $0 })

        center.request(.reveal, userInfo: ["section": "music"])

        #expect(capture.operation == .reveal)
        #expect(capture.notification == IPC.Name.requestReveal)
        #expect(capture.value == "music")
    }

    @Test func updateHistoryReadsAndClearsThroughTheSameCenter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = root.appendingPathComponent("updates.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = UpdateCheckRecord(
            date: Date(timeIntervalSince1970: 1), kind: .automatic, outcome: .upToDate)
        let recent = UpdateCheckRecord(
            date: Date(timeIntervalSince1970: 2), kind: .manual, outcome: .updateFound,
            version: "2.0")
        _ = UpdateCheckLog.append(old, to: url)
        _ = UpdateCheckLog.append(recent, to: url)
        var performed: [AppRuntimeOperation] = []
        let center = AppRuntimeCenter(willPerform: { performed.append($0) })

        #expect(center.updateHistory(limit: 1, url: url) == [recent])
        #expect(center.clearUpdateHistory(url: url) == 2)
        #expect(center.updateHistory(url: url).isEmpty)
        #expect(performed == [.updateHistory, .clearUpdateHistory, .updateHistory])
    }
}
