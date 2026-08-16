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
            let bundle = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.exportBundle()
            }
            let manifest: CompanionExportManifest
            do {
                manifest = try JSONDecoder().decode(CompanionExportManifest.self, from: bundle)
            } catch {
                throw CLIFailure(
                    "the companion sent something that is not an export bundle",
                    hint: error.localizedDescription)
            }
            do {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: true)
                try bundle.write(to: target.appendingPathComponent("bundle.json"))
            } catch {
                throw CLIFailure(
                    "could not write into \(target.path)", hint: error.localizedDescription)
            }
            var mediaSaved = 0
            var mediaFailed: [String] = []
            if includeMedia, !manifest.media.isEmpty {
                let mediaDir = target.appendingPathComponent("media")
                try? FileManager.default.createDirectory(
                    at: mediaDir, withIntermediateDirectories: true)
                for item in manifest.media {
                    let basename = (item.uri as NSString).lastPathComponent
                    let name = "\(item.sha256)-\(basename)"
                    do {
                        let (data, _) = try await CompanionBridge.request(endpoint: endpoint) {
                            client in
                            try await client.media(episodeId: item.episodeId)
                        }
                        try data.write(to: mediaDir.appendingPathComponent(name))
                        mediaSaved += 1
                    } catch {
                        mediaFailed.append(basename)
                    }
                }
            }
            let counts = manifest.counts.sorted { $0.key < $1.key }
            guard !json else {
                CLIOut.json(
                    .object([
                        "directory": .string(target.path),
                        "counts": .object(
                            counts.reduce(into: [:]) { $0[$1.key] = .int($1.value) }),
                        "mediaSaved": .int(mediaSaved),
                        "mediaFailed": .array(mediaFailed.map { .string($0) }),
                    ]))
                return
            }
            let summary = counts.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
            CLIOut.out("exported \(summary) to \(target.path)")
            if includeMedia {
                CLIOut.out("media files saved: \(mediaSaved)")
                if !mediaFailed.isEmpty {
                    CLIOut.note(
                        "media that would not download: \(mediaFailed.joined(separator: ", "))")
                }
            } else if !manifest.media.isEmpty {
                CLIOut.note(
                    "\(manifest.media.count) media file(s) stayed on the companion; add --include-media to bring them too"
                )
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
            var bundleURL = expanded
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: expanded.path, isDirectory: &isDirectory)
            guard exists else {
                throw CLIFailure.notFound("nothing at \(expanded.path)")
            }
            if isDirectory.boolValue {
                bundleURL = expanded.appendingPathComponent("bundle.json")
                guard FileManager.default.fileExists(atPath: bundleURL.path) else {
                    throw CLIFailure.notFound(
                        "no bundle.json inside \(expanded.path)",
                        hint: "point at a directory written by `ed companion export`")
                }
            }
            let data: Data
            do {
                data = try Data(contentsOf: bundleURL)
            } catch {
                throw CLIFailure(
                    "could not read \(bundleURL.path)", hint: error.localizedDescription)
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.importBundle(data)
            }
            var mediaRestored = 0
            var mediaFailed: [String] = []
            let mediaDir = bundleURL.deletingLastPathComponent().appendingPathComponent("media")
            let mediaFiles =
                (try? FileManager.default.contentsOfDirectory(atPath: mediaDir.path)) ?? []
            for name in mediaFiles.sorted() {
                guard let separator = name.firstIndex(of: "-"), separator != name.startIndex
                else { continue }
                let sha256 = String(name[..<separator])
                let basename = String(name[name.index(after: separator)...])
                guard sha256.count == 64 else { continue }
                do {
                    let bytes = try Data(contentsOf: mediaDir.appendingPathComponent(name))
                    _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                        try await client.importMedia(
                            sha256: sha256, name: basename,
                            dataB64: bytes.base64EncodedString())
                    }
                    mediaRestored += 1
                } catch {
                    mediaFailed.append(basename)
                }
            }
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
