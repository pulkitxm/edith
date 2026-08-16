import ArgumentParser
import EdithKit
import Foundation

struct CompanionExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Save everything the companion remembers as a restorable bundle.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Also download voice notes, PDFs and other media files.")
    var includeMedia = false

    @Argument(help: "The directory the bundle is written into; created if missing.")
    var directory: String

    func run() async throws {
        try await execute {
            let target = URL(
                fileURLWithPath: (directory as NSString).expandingTildeInPath, isDirectory: true)
            let include = includeMedia
            let result = try await CompanionBridge.request(endpoint: endpoint) { client in
                do {
                    return try await CompanionDataTransfer.export(
                        client: client, into: target, includeMedia: include)
                } catch let error as CompanionDataTransferError {
                    throw CLIFailure(error.errorDescription ?? "the export failed")
                }
            }
            let counts = result.counts.sorted { $0.key < $1.key }
            guard !json else {
                CLIOut.json(
                    .object([
                        "directory": .string(result.directory),
                        "counts": .object(
                            counts.reduce(into: [:]) { $0[$1.key] = .int($1.value) }),
                        "mediaSaved": .int(result.mediaSaved),
                        "mediaFailed": .array(result.mediaFailed.map { .string($0) }),
                    ]))
                return
            }
            let summary = counts.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            CLIOut.out("exported \(summary) to \(result.directory)")
            if includeMedia {
                CLIOut.out("media files saved: \(result.mediaSaved)")
                if !result.mediaFailed.isEmpty {
                    CLIOut.note(
                        "media that would not download: "
                            + result.mediaFailed.joined(separator: ", "))
                }
            } else if result.mediaOnCompanion > 0 {
                CLIOut.note(
                    "\(result.mediaOnCompanion) media file(s) stayed on the companion; "
                        + "add --include-media to bring them too")
            }
        }
    }
}

struct CompanionImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Restore a bundle written by `ed companion export`.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The bundle.json file, or the directory holding it.")
    var path: String

    func run() async throws {
        try await execute {
            let expanded = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            let result = try await CompanionBridge.request(endpoint: endpoint) { client in
                do {
                    return try await CompanionDataTransfer.restore(client: client, from: expanded)
                } catch let error as CompanionDataTransferError {
                    switch error {
                    case .missingBundle:
                        throw CLIFailure.notFound(
                            error.errorDescription ?? "no bundle.json there",
                            hint: "point at a directory written by `ed companion export`")
                    case .unreadable:
                        throw CLIFailure.notFound(error.errorDescription ?? "nothing there")
                    default:
                        throw CLIFailure(error.errorDescription ?? "the import failed")
                    }
                }
            }
            let outcome = result.outcome
            let mediaRestored = result.mediaRestored
            let mediaFailed = result.mediaFailed
            guard !json else {
                CLIOut.json(
                    .object([
                        "episodesInserted": .int(outcome.episodesInserted),
                        "episodesSkipped": .int(outcome.episodesSkipped),
                        "observationsInserted": .int(outcome.observationsInserted),
                        "conversationsInserted": .int(outcome.conversationsInserted),
                        "messagesInserted": .int(outcome.messagesInserted),
                        "beliefsInserted": .int(outcome.beliefsInserted),
                        "claimsInserted": .int(outcome.claimsInserted),
                        "factsInserted": .int(outcome.factsInserted),
                        "coreSectionsInserted": .int(outcome.coreSectionsInserted),
                        "settingsInserted": .int(outcome.settingsInserted),
                        "mediaRestored": .int(mediaRestored),
                        "mediaFailed": .array(mediaFailed.map { .string($0) }),
                        "pendingEpisodes": .int(outcome.pendingEpisodes),
                    ]))
                return
            }
            CLIOut.out(
                "restored \(outcome.episodesInserted) episode(s), "
                    + "\(outcome.observationsInserted) observation(s), "
                    + "\(outcome.conversationsInserted) conversation(s), "
                    + "\(outcome.beliefsInserted) belief(s)")
            if outcome.episodesSkipped > 0 {
                CLIOut.out("already there: \(outcome.episodesSkipped) episode(s)")
            }
            if mediaRestored > 0 || !mediaFailed.isEmpty {
                CLIOut.out("media restored: \(mediaRestored)")
                if !mediaFailed.isEmpty {
                    CLIOut.note(
                        "media that would not restore: \(mediaFailed.joined(separator: ", "))")
                }
            }
            if outcome.pendingEpisodes > 0 {
                CLIOut.out(
                    "\(outcome.pendingEpisodes) episode(s) queued for embedding; the companion is indexing them now"
                )
            }
        }
    }
}

struct CompanionEraseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "erase",
        abstract: "Delete one episode, its media, and everything derived from it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Actually delete; without it nothing happens.")
    var yes = false

    @Argument(help: "The episode id to erase.")
    var id: String

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage(
                    "erasing an episode cannot be undone",
                    hint:
                        "run `ed companion episode \(id)` to read it first, then repeat with --yes")
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.deleteEpisode(id: id)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "erased": .string(outcome.id),
                        "claimsDeleted": .int(outcome.claimsDeleted),
                        "chunksDeleted": .int(outcome.chunksDeleted),
                        "sourceDeleted": .bool(outcome.sourceDeleted),
                        "vaultFileRemoved": .bool(outcome.vaultFileRemoved),
                    ]))
                return
            }
            CLIOut.out(
                "erased episode \(outcome.id): \(outcome.chunksDeleted) chunk(s), "
                    + "\(outcome.claimsDeleted) claim(s)"
                    + (outcome.vaultFileRemoved ? ", and its vault file" : ""))
        }
    }
}

struct CompanionWipeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wipe",
        abstract: "Delete every episode, observation, belief and conversation.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Actually wipe; without it nothing happens.")
    var yes = false

    func run() async throws {
        try await execute {
            guard yes else {
                throw CLIFailure.usage(
                    "wiping deletes the companion's entire memory and cannot be undone",
                    hint: "run `ed companion export <dir>` first, then repeat with --yes")
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.wipe(confirm: "everything")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "episodesDropped": .int(outcome.episodesDropped),
                        "sourcesDropped": .int(outcome.sourcesDropped),
                        "observationsDropped": .int(outcome.observationsDropped),
                        "conversationsDropped": .int(outcome.conversationsDropped),
                        "beliefsDropped": .int(outcome.beliefsDropped),
                        "vaultCleared": .bool(outcome.vaultCleared),
                    ]))
                return
            }
            CLIOut.out(
                "wiped \(outcome.episodesDropped) episode(s), "
                    + "\(outcome.observationsDropped) observation(s), "
                    + "\(outcome.beliefsDropped) belief(s), "
                    + "\(outcome.conversationsDropped) conversation(s)")
            CLIOut.out(
                outcome.vaultCleared
                    ? "the vault is empty" : "some vault files would not delete")
        }
    }
}
