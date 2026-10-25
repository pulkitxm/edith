import ArgumentParser
import ArgumentParserToolInfo
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@MainActor @Suite struct CalendarCLIContextTests {
    @Test func fullRequestReachesOriginalReadWithoutChangingStreamsOrExit() async throws {
        let event = event("context")
        let baseline = try await CalendarCLIExecution.run(.init(arguments: ["ls", "--json"])) {
            _ in [event]
        }
        let request = try ExtensionCLIRequest(
            arguments: ["ls", "--json"], standardInput: Data([0, 47, 255]),
            workingDirectory: "/synthetic/calendar/context", interactive: true)
        var captured: ExtensionCLIRequest?
        let actual = try await CalendarCLIExecution.run(request) { _ in
            captured = ExtensionCLIContext.request
            return [event]
        }
        #expect(captured == request && actual == baseline)
        #expect(actual.stderr.isEmpty && actual.exitCode == 0)
        #expect(ExtensionCLIContext.request == nil)
    }

    @Test func overlappingOriginalCommandsKeepTheirOwnReadServicesAndContexts() async throws {
        let gate = CalendarCLIReadGate()
        let firstRequest = try ExtensionCLIRequest(
            arguments: ["ls", "--json"], workingDirectory: "/synthetic/first")
        let first = Task {
            try await CalendarCLIExecution.run(firstRequest) { _ in
                await gate.wait()
                #expect(ExtensionCLIContext.request == firstRequest)
                return [self.event("first")]
            }
        }
        await gate.entered()
        let secondRequest = try ExtensionCLIRequest(
            arguments: ["ls", "--json"], workingDirectory: "/synthetic/second")
        let second = try await CalendarCLIExecution.run(secondRequest) { _ in
            #expect(ExtensionCLIContext.request == secondRequest)
            return [self.event("second")]
        }
        gate.release()
        let reply = try await first.value
        #expect(reply.stdout.contains("first") && !reply.stdout.contains("second"))
        #expect(second.stdout.contains("second") && !second.stdout.contains("first"))
        #expect(reply.exitCode == 0 && second.exitCode == 0)
    }

    @Test func catalogPreservesOriginalParserTreeAndEveryCanonicalCommand() throws {
        let catalog = try JSONDecoder().decode(
            CalendarCLICatalog.self, from: CalendarCLICatalog.encoded(Data("{}".utf8)))
        let original = try JSONDecoder().decode(
            ToolInfoV0.self, from: Data(CalendarCommand._dumpHelp().utf8))
        #expect(catalog.owner == "calendar" && catalog.version == 1)
        #expect(catalog.parserHelp == [original])
        #expect(catalog.settings.isEmpty && !catalog.acceptsInput)
        #expect(
            Set(catalog.commands.map(\.route)) == [
                ["calendar"], ["calendar", "ls"], ["calendar", "open"],
                ["calendar", "join"], ["calendar", "directions"], ["calendar", "help"],
            ])
        #expect(
            catalog.commands.allSatisfy {
                $0.operation == "calendar.cli" && !$0.destructive && !$0.readsInput
                    && $0.jsonOutput == ($0.route.last != "help") && $0.timeout == 30
            })
        #expect(original.command.defaultSubcommand == "ls")
        #expect(original.command.subcommands?.first { $0.commandName == "ls" }?.aliases == ["list"])
        #expect(
            original.command.subcommands?.first { $0.commandName == "directions" }?.aliases == [
                "route"
            ])
        #expect(throws: (any Error).self) {
            try CalendarCLICatalog.encoded(Data("{\"route\":\"other\"}".utf8))
        }
    }

    private func event(_ id: String) -> CalendarEventPayload {
        let start = Date().addingTimeInterval(600)
        return CalendarEventPayload(
            id: id, title: "Synthetic \(id)", start: start, end: start.addingTimeInterval(600),
            isAllDay: false)
    }
}

@MainActor private final class CalendarCLIReadGate {
    private var read: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            read = $0
            observer?.resume()
            observer = nil
        }
    }

    func entered() async {
        if read != nil { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        read?.resume()
        read = nil
    }
}
