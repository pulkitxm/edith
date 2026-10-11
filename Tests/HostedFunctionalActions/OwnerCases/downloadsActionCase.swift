import EdithExtensionSupport
import Foundation
import FunctionalActionContract

@testable import DownloadsExtension

@MainActor
final class DownloadsActionCase: HostedFunctionalActionCase {
    static let owner = "downloads"
    static let activationOperation = "downloads.ui.action"
    private let transport: HostedFunctionalActionTransport
    private let client: ExtensionEngineClient
    private let model: YoutubeDownloader

    init(transport: HostedFunctionalActionTransport) throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HOME"] == transport.context.home,
            environment["CFFIXED_USER_HOME"] == transport.context.home,
            environment["EDITH_EXTENSION_DATA_ROOT"] == transport.context.dataDirectory,
            environment["EDITH_SHARED_DEFAULTS_SUITE"] == transport.context.hostIdentifier + ".functional.ui." + Self.owner + "." + transport.context.phase
        else { throw HostedFunctionalActionError.invalid }
        guard transport.context.owner == Self.owner else { throw HostedFunctionalActionError.invalid }
        self.transport = transport
        client = try transport.makeEngineClient()
        model = YoutubeDownloader(
            client: DownloadsClient(client: client), start: false,
            remote: DownloadsUIBridge(client: client))
    }

    func activateOriginalControl(context: HostedFunctionalActionContext) async throws {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let count = transport.originalInvocationCount
        model.setPreferredKind(.audio)
        try await transport.waitForOriginalInvocation(Self.activationOperation, after: count)
    }

    func readAuthoritativeState(context: HostedFunctionalActionContext) async throws -> Data {
        guard context == transport.context else { throw HostedFunctionalActionError.invalid }
        let configuration = try JSONDecoder().decode(
            DownloadsUIConfiguration.self,
            from: await transport.readAuthoritative("downloads.ui.configuration"))
        let audio = try context.ownedPath(named: "audio-library", kind: "directory")
        guard configuration.kind == .audio, configuration.directories["audio"] == audio else {
            throw HostedFunctionalActionError.invalid
        }
        let snapshot = try JSONDecoder().decode(
            DownloadWorkerSnapshot.self,
            from: await transport.readAuthoritative("download.worker.snapshot"))
        guard snapshot.records.count == 1, let record = snapshot.records.first,
            record.title == "Synthetic saved download", record.kind == .audio, record.resultPaths == [audio.appendingPathComponent("Synthetic saved download.m4a").path]
        else { throw HostedFunctionalActionError.invalid }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Retained(kind: configuration.kind, audio: audio, records: snapshot.records))
    }

    func readPersistentState(context: HostedFunctionalActionContext) async throws -> Data? {
        try await readAuthoritativeState(context: context)
    }

    private struct Retained: Codable {
        let kind: DownloadKind
        let audio: URL
        let records: [DownloadRecord]
    }

    func shutdownPresentation() async {
        await model.shutdown()
        client.invalidate()
    }
}
