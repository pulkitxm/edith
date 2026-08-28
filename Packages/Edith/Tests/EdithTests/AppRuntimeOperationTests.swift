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

    @Test func everyOperationHasOneExactInterfaceExposure() {
        let operationIDs = Set(AppRuntimeOperation.allCases.map(\.descriptor.id))
        let registrations = UserOperationCatalog.registrations.filter {
            operationIDs.contains($0.descriptor.id)
        }
        let actions = UserInterfaceActionCatalog.actions.filter {
            operationIDs.contains($0.operation.id)
        }
        let expectedActions = [
            ("app.clean-keys", "Menu bar", "lock the keyboard to clean it", []),
            ("app.clean-keys", "Extension settings", "lock the keyboard to clean it", []),
            ("app.test-notification", "Settings", "send a test notification", []),
            (
                "app.test-notification", "Extension settings", "send a test notification",
                []
            ),
            ("app.open", "Menu bar", "open the panel", []),
            ("app.quit", "Menu bar", "quit Edith", ["--yes"]),
            ("app.check-updates", "About pane", "check for updates", []),
            ("app.update-history", "Update schedule sheet", "read the check history", []),
            ("app.relaunch", "Permissions pane", "relaunch after granting", ["--yes"]),
            (
                "app.clear-updates", "Update schedule sheet", "clear the check history",
                ["--yes"]
            ),
        ]
        let actualActions = actions.map {
            ($0.operation.id.rawValue, $0.surface, $0.action, $0.exampleArguments)
        }

        #expect(registrations.count == AppRuntimeOperation.allCases.count)
        #expect(Set(registrations.map(\.descriptor.id)) == operationIDs)
        #expect(actualActions.elementsEqual(expectedActions, by: ==))
        #expect(
            Set(UserOperationCatalog.commandLineOnly.map(\.descriptor.id))
                .intersection(operationIDs)
                == [
                    AppRuntimeOperation.reveal.descriptor.id,
                    AppRuntimeOperation.snapshot.descriptor.id,
                ])
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

    @Test func keyboardCleaningPayloadsPreserveCorrelationAndState() {
        let requestID = UUID().uuidString
        for state in [
            KeyboardCleaningState.arming, .cleaning, .inputMonitoringRequired,
            .accessibilityRequired, .unavailable,
        ] {
            let payload = KeyboardCleaningIPC.payload(requestID: requestID, state: state)
            #expect(payload[KeyboardCleaningIPC.requestIDKey] as? String == requestID)
            #expect(KeyboardCleaningIPC.state(from: payload) == state)
            #expect(state.accepted == (state == .arming || state == .cleaning))
        }
    }

    @Test func relaunchStartsTheBundleBeforeTerminatingThroughTheTypedOperation() {
        final class Capture {
            var events: [String] = []
            var operations: [AppRuntimeOperation] = []
        }
        let capture = Capture()
        let bundle = URL(fileURLWithPath: "/Applications/EdithHelper.app")
        let center = AppRuntimeCenter(willPerform: { capture.operations.append($0) })

        center.relaunchCurrentApplication(
            at: bundle,
            launch: { capture.events.append("launch:\($0.path)") },
            terminate: { capture.events.append("terminate") })

        #expect(capture.operations == [.relaunch])
        #expect(capture.events == ["launch:\(bundle.path)", "terminate"])
    }

    @Test func completeQuitRequestsTheMainAppBeforeTerminatingTheHelper() {
        final class Capture {
            var events: [String] = []
            var operations: [AppRuntimeOperation] = []
        }
        let capture = Capture()
        let center = AppRuntimeCenter(
            post: { name, _ in capture.events.append("post:\(name.rawValue)") },
            willPerform: {
                capture.operations.append($0)
                capture.events.append("operation:\($0.rawValue)")
            })

        center.quitCompletely(terminate: { capture.events.append("terminate") })

        #expect(capture.operations == [.quit])
        #expect(
            capture.events == [
                "operation:quit", "post:\(IPC.Name.quitMainApp.rawValue)", "terminate",
            ])
    }

    @Test func asynchronousExecutionRecordsTheTypedOperationBeforeWork() async {
        final class Capture {
            var events: [String] = []
        }
        let capture = Capture()
        let center = AppRuntimeCenter(willPerform: {
            capture.events.append("operation:\($0.rawValue)")
        })

        let value = await center.perform(.relaunch) {
            await Task.yield()
            capture.events.append("work")
            return 7
        }

        #expect(value == 7)
        #expect(capture.events == ["operation:relaunch", "work"])
    }

    @Test func helperLifecycleSurfacesUseTheSharedCenter() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EdithHelper")
        let developer = try String(
            contentsOf: sources.appendingPathComponent(
                "Features/System/Views/DeveloperPanel.swift"), encoding: .utf8)
        let system = try String(
            contentsOf: sources.appendingPathComponent(
                "Features/System/ViewModels/SystemStore.swift"), encoding: .utf8)
        let menu = try String(
            contentsOf: sources.appendingPathComponent("Core/Navigation/StatusItemMenu.swift"),
            encoding: .utf8)
        let helper = try String(
            contentsOf: sources.appendingPathComponent("Core/Application/EdithHelperApp.swift"),
            encoding: .utf8)
        let cli = try String(
            contentsOf: sources.deletingLastPathComponent().appendingPathComponent(
                "EdithCLI/Commands/AppCommands.swift"), encoding: .utf8)
        let updater = try String(
            contentsOf: sources.deletingLastPathComponent().appendingPathComponent(
                "Edith/Core/Application/UpdaterModel.swift"), encoding: .utf8)

        #expect(developer.contains("AppRuntimeCenter().relaunchCurrentApplication()"))
        #expect(system.contains("AppRuntimeCenter().relaunchCurrentApplication()"))
        #expect(menu.contains("AppRuntimeCenter().quitCompletely()"))
        #expect(helper.contains("AppRuntimeCenter().quitCompletely()"))
        #expect(cli.contains("AppActions.runtime.perform(.relaunch)"))
        #expect(!developer.contains("private func relaunch"))
        #expect(!developer.contains("NSApp.terminate"))
        #expect(!developer.contains("NSWorkspace.shared.openApplication"))
        #expect(!system.contains("task.executableURL"))
        #expect(!system.contains("NSApp.terminate"))
        #expect(!menu.contains("NSApp.terminate"))
        #expect(!helper.contains("NSApp.terminate"))
        #expect(updater.contains("checkHistory = AppRuntimeCenter().updateHistory(url: logURL)"))
        #expect(!updater.contains("checkHistory = UpdateCheckLog.load"))
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
