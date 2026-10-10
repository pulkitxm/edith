import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostCLIProviderTests {
    @Test func catalogsCannotClaimCoreOrAnotherExtensionsRoutes() throws {
        for route in [["config", "set"], ["app", "quit"], ["calendar", "ls"]] {
            let catalog = HostCLIProviderCatalog(
                owner: "music",
                commands: [.init(route: route, operation: "music.cli", summary: "Read tracks")])
            #expect(throws: HostCLIError.self) { try catalog.validate(owner: "music") }
        }
        let valid = HostCLIProviderCatalog(
            owner: "music",
            commands: [
                .init(route: ["music", "ls"], operation: "music.cli", summary: "Read tracks")
            ])
        #expect(
            try HostCLIProviderCatalog.decode(JSONEncoder().encode(valid), owner: "music").commands
                == valid.commands)
        #expect(throws: HostCLIError.self) { try valid.validate(owner: "calendar") }
    }

    @Test func unavailableProvidersAreNeverDiscoveredOrEnabled() async throws {
        let fixture = ProviderFixture(available: false)
        let registry = try await HostCLIProviderRegistry.load(invoke: {
            try await fixture.invoke($0)
        })
        #expect(registry.providers.isEmpty)
        #expect(await fixture.actions() == [.ls, .ls])
    }

    @Test func providerArgumentsAndExactTerminalResultSurviveRouting() async throws {
        let fixture = ProviderFixture()
        let registry = try await HostCLIProviderRegistry.load(invoke: {
            try await fixture.invoke($0)
        })
        let result = try await registry.execute(
            ["music", "ls", "--json"], invoke: { try await fixture.invoke($0) })
        #expect(
            result.stdout == "output without newline" && result.stderr == "diagnostic\n"
                && result.exitCode == 130)
        #expect(await fixture.arguments() == ["ls", "--json"])
        #expect(await fixture.actions().allSatisfy { $0 == .ls || $0 == .invoke })
    }

    @Test func disableDuringExecutionDiscardsStaleReply() async throws {
        let fixture = ProviderFixture(disableOnExecution: true)
        let registry = try await HostCLIProviderRegistry.load(invoke: {
            try await fixture.invoke($0)
        })
        await #expect(throws: HostCLIError.self) {
            try await registry.execute(["music", "ls"], invoke: { try await fixture.invoke($0) })
        }
    }

    @Test func cancellationDuringDiscoveryIsPropagated() async throws {
        let fixture = ProviderFixture(cancelCatalog: true)
        await #expect(throws: CancellationError.self) {
            try await HostCLIProviderRegistry.load(invoke: { try await fixture.invoke($0) })
        }
    }

    @Test func stdinRequiresExplicitProviderSupportAndBoundedBytes() throws {
        let catalog = HostCLIProviderCatalog(
            owner: "latex",
            commands: [
                .init(route: ["latex", "write"], operation: "latex.cli", summary: "Write source")
            ])
        #expect(throws: HostCLIError.self) {
            try HostCLIProviderRegistry.request(
                arguments: ["write"], input: Data("synthetic".utf8), catalog: catalog)
        }
        let withInput = HostCLIProviderCatalog(
            owner: catalog.owner, commands: catalog.commands, acceptsInput: true)
        let data = try HostCLIProviderRegistry.request(
            arguments: ["write"], input: Data("synthetic".utf8), catalog: withInput)
        let payload = try JSONDecoder().decode(HostCLIJSON.self, from: data)
        #expect(payload.object?["input"]?.string == Data("synthetic".utf8).base64EncodedString())
        #expect(throws: HostCLIError.self) {
            try HostCLIProviderRegistry.request(
                arguments: ["write"], input: Data(count: 256 * 1024 + 1), catalog: withInput)
        }
    }

    @Test func settingsRejectWrongTypesRangesAndNonFiniteValues() throws {
        let setting = HostCLISetting(
            "threshold", .int, group: "sample", summary: "Threshold", minimum: 0, maximum: 100,
            fallback: .integer(20))
        try setting.validate()
        #expect(try setting.parse("40") == .integer(40))
        #expect(throws: HostCLIError.self) { try setting.parse("101") }
        #expect(throws: HostCLIError.self) { try setting.coerce(.bool(true)) }
        let number = HostCLISetting("zoom", .number, group: "sample", summary: "Zoom")
        #expect(throws: HostCLIError.self) { try number.parse("nan") }
    }
}

private actor ProviderFixture {
    private var available: Bool
    private let disableOnExecution: Bool
    private let cancelCatalog: Bool
    private var requests: [HostCLIRequest] = []
    private var lastArguments: [String] = []

    init(available: Bool = true, disableOnExecution: Bool = false, cancelCatalog: Bool = false) {
        self.available = available; self.disableOnExecution = disableOnExecution;
        self.cancelCatalog = cancelCatalog
    }
    func actions() -> [HostCLIRequest.Action] { requests.map(\.action) }
    func arguments() -> [String] { lastArguments }
    func invoke(_ request: HostCLIRequest) throws -> Data {
        requests.append(request)
        if request.action == .ls {
            return try HostCLIJSON.array([
                .object([
                    "id": .string("music"), "installed": .bool(true), "compatible": .bool(true),
                    "enabled": .bool(available), "running": .bool(available),
                    "version": .string("1.2.3"),
                    "disablePending": .bool(false), "removalPending": .bool(false),
                ])
            ]).encoded()
        }
        if request.operation == "music.cli.catalog" {
            if cancelCatalog { throw CancellationError() }
            return try JSONEncoder().encode(
                HostCLIProviderCatalog(
                    owner: "music",
                    commands: [
                        .init(
                            route: ["music", "ls"], operation: "music.cli", summary: "Read tracks")
                    ]))
        }
        #expect(request.id == "music" && request.operation == "music.cli")
        lastArguments = try JSONDecoder().decode(ExtensionCLIRequest.self, from: request.payload)
            .arguments
        if disableOnExecution { available = false }
        return try JSONEncoder().encode(
            ExtensionCLIReply(
                stdout: "output without newline", stderr: "diagnostic\n", exitCode: 130))
    }
}

@MainActor @Suite(.serialized) struct HostCommandCLITransportTests {
    @Test func cancellationDisconnectsAuthenticatedSocketAndCancelsOwnedServerWork() async throws {
        let identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.command-\(UUID().uuidString)",
            supportDirectory: FileManager.default.temporaryDirectory)
        var started = false
        var cancelled = false
        let server = HostCLIServer(identity: identity) { _ in
            started = true
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
            return Data("{}".utf8)
        }
        try server.start()
        defer { server.shutdown() }
        let task = Task {
            try await HostCommandCLITransport.invoke(
                HostCLIRequest(action: .ls), identity: identity)
        }
        for _ in 0..<100 where !started { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<100 where !cancelled { try await Task.sleep(for: .milliseconds(10)) }
        #expect(cancelled)
    }
}
