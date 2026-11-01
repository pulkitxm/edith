import EdithExtensionCore
import Foundation
import Testing

@Suite struct ExtensionScopeRegistryTests {
    private func scope(id: String, worker: Bool) -> ExtensionScope {
        let values = ["EDITH_EXTENSION_ID": id, "EDITH_EXTENSION_WORKER": worker ? "1" : ""]
        let root = URL(fileURLWithPath: "/tmp/edith-scope-\(id)")
        return ExtensionScope(
            environment: { values }, value: { values[$0] }, defaults: { .standard },
            dataRoot: { root })
    }

    @Test func eachImageResolvesItsOwnScope() throws {
        let first = try #require(UnsafeRawPointer(bitPattern: 0x7000_1000))
        let second = try #require(UnsafeRawPointer(bitPattern: 0x7000_2000))
        ExtensionScope.register(scope(id: "alpha", worker: true), image: first)
        ExtensionScope.register(scope(id: "beta", worker: false), image: second)
        #expect(ExtensionScope.resolve(first)["EDITH_EXTENSION_ID"] == "alpha")
        #expect(ExtensionScope.resolve(second)["EDITH_EXTENSION_ID"] == "beta")
        #expect(ExtensionScope.resolve(second).dataRoot().lastPathComponent == "edith-scope-beta")
        #expect(
            ExtensionCommandOwner(image: first)
                == ExtensionCommandOwner(id: "alpha", isWorker: true))
        #expect(ExtensionCommandOwner(image: second).isWorker == false)
    }

    @Test func unknownImagesUseTheProcessScope() throws {
        let unknown = try #require(UnsafeRawPointer(bitPattern: 0x7000_3000))
        #expect(
            ExtensionScope.resolve(unknown)["EDITH_EXTENSION_ID"]
                == ProcessInfo.processInfo.environment["EDITH_EXTENSION_ID"])
    }

    @Test func requestsRecordTheirOwnerButDoNotEncodeIt() throws {
        let image = try #require(UnsafeRawPointer(bitPattern: 0x7000_4000))
        ExtensionScope.register(scope(id: "gamma", worker: true), image: image)
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [], environment: [:],
            image: image)
        #expect(request.owner == ExtensionCommandOwner(id: "gamma", isWorker: true))
        let decoded = try JSONDecoder().decode(
            CLICommandRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.owner == .host)
        #expect(decoded.arguments == request.arguments)
    }
}
