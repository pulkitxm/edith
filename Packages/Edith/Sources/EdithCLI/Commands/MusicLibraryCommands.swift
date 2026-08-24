import ArgumentParser
import EdithKit
import Foundation

enum LibraryBridge {
    static func requireFolder() throws {
        guard
            let path = CLIEnvironment.sharedDefaults.string(forKey: Repo.musicFolderPathKey),
            !path.isEmpty
        else {
            throw CLIFailure.unavailable(
                "no music folder is set",
                hint: "choose one in Edith under Music, or run `ed config set musicFolderPath "
                    + "~/Music`")
        }
    }

    static func track(_ query: String) throws -> Track {
        try requireFolder()
        if let exact = try? MusicLibrary.track(at: query) { return exact }
        let needle = query.lowercased()
        let all = TrackMeta.scanMusicFolder()
        let matches = all.filter {
            $0.relativePath.lowercased().contains(needle)
                || $0.title.lowercased().contains(needle)
        }
        if matches.count == 1, let only = matches.first { return only }
        if matches.count > 1 {
            throw CLIFailure.notFound(
                "\(query) matches \(matches.count) tracks",
                hint: matches.prefix(5).map(\.relativePath).joined(separator: ", "))
        }
        throw CLIFailure.notFound(
            "no track matching \(query)", hint: "run `ed music ls` to see what is there")
    }

    static func folder(_ path: String) throws -> MusicFolder {
        try requireFolder()
        do {
            return try MusicLibrary.folder(at: path)
        } catch {
            throw CLIFailure.notFound(
                "no folder called \(path)", hint: "run `ed music ls --folders` to see them")
        }
    }

    static func fail(_ error: Error) -> CLIFailure {
        guard let library = error as? MusicLibraryError else {
            return CLIFailure(error.localizedDescription)
        }
        switch library {
        case .emptyName: return CLIFailure("a name cannot be blank")
        case let .alreadyThere(path): return CLIFailure("\(path) is already there")
        case let .noSuchTrack(path): return CLIFailure.notFound("no track at \(path)")
        case let .noSuchFolder(path): return CLIFailure.notFound("no folder at \(path)")
        case let .failed(message): return CLIFailure(message)
        }
    }

    static func announce() {
        AppBridge.post(IPC.Name.musicFolderChanged)
    }

    static func send(_ request: MusicTransportRequest) {
        MusicTransportExecution.perform(
            request,
            sendCommand: { AppBridge.post(IPC.Name.musicCommand, userInfo: $0) },
            requestStatus: { AppBridge.post(IPC.Name.requestMusicState) })
    }

    static func json(_ track: Track) -> JSONValue {
        .object([
            "path": .string(track.relativePath),
            "title": .string(track.title),
            "file": .string(track.url.lastPathComponent),
        ])
    }
}

struct MusicListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the music library, a folder at a time.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Only folders.")
    var folders = false

    @Flag(help: "Every track underneath, not just this folder.")
    var recursive = false

    @Option(help: "Only entries whose path or title contains this text.")
    var search: String?

    @Argument(help: "Folder to list, relative to the library root.")
    var folder: String = ""

    func run() async throws {
        try await execute {
            let target = try LibraryBridge.folder(folder)
            let listing = MusicLibraryContentOperationExecution.list(
                target, recursive: recursive)
            let needle = (search ?? "").lowercased()
            let shown =
                needle.isEmpty
                ? listing.tracks
                : listing.tracks.filter {
                    $0.relativePath.lowercased().contains(needle)
                        || $0.title.lowercased().contains(needle)
                }
            guard !json else {
                CLIOut.json(
                    .object([
                        "folder": .string(target.relativePath),
                        "folders": .array(
                            listing.folders.map {
                                .object([
                                    "path": .string($0.relativePath),
                                    "name": .string($0.name),
                                    "tracks": .int(
                                        TrackMeta.trackCount(under: $0.relativePath)),
                                ])
                            }),
                        "tracks": .array(folders ? [] : shown.map(LibraryBridge.json)),
                    ]))
                return
            }
            if !listing.folders.isEmpty {
                CLIOut.out(
                    TextTable.render(
                        headers: ["FOLDER", "TRACKS"],
                        rows: listing.folders.map {
                            [$0.relativePath, String(TrackMeta.trackCount(under: $0.relativePath))]
                        }))
            }
            guard !folders else { return }
            guard !shown.isEmpty else {
                if listing.folders.isEmpty { CLIOut.note("nothing here") }
                return
            }
            if !listing.folders.isEmpty { CLIOut.out("") }
            CLIOut.out(
                TextTable.render(
                    headers: ["TITLE", "PATH"],
                    rows: shown.map { [$0.title, $0.relativePath] }))
        }
    }
}

struct MusicNewFolderCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mkdir", abstract: "Make a folder in the library.", aliases: ["newfolder"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Folder to make it inside, relative to the library root.")
    var under: String = ""

    @Argument(help: "What to call it.")
    var name: String

    func run() async throws {
        try await execute {
            _ = try LibraryBridge.folder(under)
            let made: MusicFolder
            do {
                made = try MusicLibraryContentOperationExecution.createFolder(
                    named: name, under: under)
            } catch {
                throw LibraryBridge.fail(error)
            }
            LibraryBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(made.relativePath), "name": .string(made.name),
                    ]))
                return
            }
            CLIOut.out("made \(made.relativePath)")
        }
    }
}

struct MusicMoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mv", abstract: "Move a track into a folder.", aliases: ["move"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Track path, or enough of its name to be unambiguous.")
    var track: String

    @Argument(help: "Destination folder, relative to the library root.")
    var folder: String

    func run() async throws {
        try await execute {
            let found = try LibraryBridge.track(track)
            _ = try LibraryBridge.folder(folder)
            let move: MusicLibrary.Move
            do {
                move = try MusicLibraryContentOperationExecution.move(found, to: folder)
            } catch {
                throw LibraryBridge.fail(error)
            }
            AppBridge.post(
                IPC.Name.musicCommand,
                userInfo: ["action": "renamed", "from": move.from, "to": move.to])
            LibraryBridge.announce()
            guard !json else {
                CLIOut.json(.object(["from": .string(move.from), "to": .string(move.to)]))
                return
            }
            CLIOut.out("moved to \(move.to)")
        }
    }
}

struct MusicRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename a track or a folder.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Rename a folder rather than a track.")
    var folder = false

    @Argument(help: "Track path or folder path.")
    var target: String

    @Argument(help: "The new name, without the extension.")
    var name: String

    func run() async throws {
        try await execute {
            let move: MusicLibrary.Move
            do {
                let target: MusicLibraryRenameTarget =
                    folder
                    ? .folder(try LibraryBridge.folder(target))
                    : .track(try LibraryBridge.track(target))
                move = try MusicLibraryContentOperationExecution.rename(target, to: name)
            } catch let failure as CLIFailure {
                throw failure
            } catch {
                throw LibraryBridge.fail(error)
            }
            AppBridge.post(
                IPC.Name.musicCommand,
                userInfo: ["action": "renamed", "from": move.from, "to": move.to])
            LibraryBridge.announce()
            guard !json else {
                CLIOut.json(.object(["from": .string(move.from), "to": .string(move.to)]))
                return
            }
            CLIOut.out("renamed to \(move.to)")
        }
    }
}

struct MusicRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Move a track or folder to the Trash.",
        discussion: """
            Nothing is deleted outright: this puts the file in the Trash, the same as the
            UI does, so it can be put back from Finder.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Remove a folder and everything in it.")
    var folder = false

    @Flag(help: "Actually do it. Without this nothing is moved.")
    var yes = false

    @Argument(help: "Track path or folder path.")
    var target: String

    func run() async throws {
        try await execute {
            let target: MusicLibraryRemovalTarget =
                folder
                ? .folder(try LibraryBridge.folder(target))
                : .track(try LibraryBridge.track(target))
            let plan = MusicLibraryContentOperationExecution.removalPlan(target)
            guard yes else { return preview(plan.path, count: plan.trackCount) }
            do {
                try MusicLibraryContentOperationExecution.remove(plan)
            } catch {
                throw LibraryBridge.fail(error)
            }
            LibraryBridge.announce()
            guard !json else {
                CLIOut.json(
                    .object([
                        "path": .string(plan.path), "tracks": .int(plan.trackCount),
                        "trashed": .bool(true),
                    ]))
                return
            }
            CLIOut.out("moved \(plan.path) to the Trash")
        }
    }

    private func preview(_ path: String, count: Int) {
        guard !json else {
            CLIOut.json(
                .object(["path": .string(path), "tracks": .int(count), "trashed": .bool(false)]))
            return
        }
        CLIOut.out("would move \(path) to the Trash (\(count) track(s))")
        CLIOut.note("nothing was moved; pass --yes to go ahead")
    }
}

struct MusicPlayTrackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Play one track, or everything in a folder.",
        discussion: """
            This drives Edith's own library player, so it needs the app running. `ed music
            play` without a track resumes whatever player is already going, including
            Spotify and Apple Music.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Treat the argument as a folder and play everything under it.")
    var folder = false

    @Argument(help: "Track path or title, or a folder path with --folder.")
    var target: String

    func run() async throws {
        try await execute {
            try AppBridge.requireHelper("playing from the library")
            guard !folder else {
                let found = try LibraryBridge.folder(target)
                LibraryBridge.send(.startSource(.folder(found.relativePath)))
                guard !json else {
                    CLIOut.json(
                        .object([
                            "playing": .string(found.relativePath), "folder": .bool(true),
                        ]))
                    return
                }
                CLIOut.out("playing \(found.relativePath)")
                return
            }
            let track = try LibraryBridge.track(target)
            LibraryBridge.send(.startTrack(track.relativePath))
            guard !json else {
                CLIOut.json(LibraryBridge.json(track))
                return
            }
            CLIOut.out("playing \(track.title)")
        }
    }
}

struct MusicSeekCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "seek", abstract: "Jump to a point in the current track, from 0 to 1.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Where to jump to, as a fraction of the track from 0 to 1.")
    var position: Double

    func run() async throws {
        try await execute {
            let fraction = try ArgumentChecks.fraction(position, "position")
            try AppBridge.requireHelper("seeking")
            LibraryBridge.send(.seek(fraction))
            guard !json else {
                CLIOut.json(.object(["position": .double(fraction)]))
                return
            }
            CLIOut.out("seeked to \(Int(fraction * 100))%")
        }
    }
}

struct MusicShuffleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shuffle", abstract: "Turn shuffle on or off.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "on or off. Leave it out to report what it is.")
    var state: String?

    func run() async throws {
        try await MusicToggleState.apply(
            key: AppStorageKeys.Music.shuffling, label: "shuffle", state: state, json: json,
            request: MusicTransportRequest.shuffle)
    }
}

struct MusicRepeatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "repeat", abstract: "Turn repeat on or off.", aliases: ["loop"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "on or off. Leave it out to report what it is.")
    var state: String?

    func run() async throws {
        try await MusicToggleState.apply(
            key: AppStorageKeys.Music.looping, label: "repeat", state: state, json: json,
            request: MusicTransportRequest.repeat)
    }
}

enum MusicToggleState {
    static func apply(
        key: String, label: String, state: String?, json: Bool,
        request: (Bool) -> MusicTransportRequest
    ) async throws {
        try await execute {
            let defaults = CLIEnvironment.standardDefaults
            guard let state else {
                let on = defaults.bool(forKey: key)
                guard !json else {
                    CLIOut.json(.object([label: .bool(on)]))
                    return
                }
                CLIOut.out(on ? "on" : "off")
                return
            }
            guard let wanted = BooleanWord.parse(state) else {
                throw CLIFailure(
                    "\(state) is not on or off", hint: "pass on, off, true or false")
            }
            defaults.set(wanted, forKey: key)
            LibraryBridge.send(request(wanted))
            guard !json else {
                CLIOut.json(.object([label: .bool(wanted)]))
                return
            }
            CLIOut.out("\(label) \(wanted ? "on" : "off")")
        }
    }
}

enum BooleanWord {
    static func parse(_ raw: String) -> Bool? {
        switch raw.lowercased() {
        case "on", "true", "yes", "1", "enabled": return true
        case "off", "false", "no", "0", "disabled": return false
        default: return nil
        }
    }
}

enum MusicFavouriteBridge {
    static func run(_ operation: MusicLibraryOperation, query: String, json: Bool) throws {
        let track = try LibraryBridge.track(query)
        let result = MusicLibraryOperationExecution.setFavourite(
            operation, path: track.relativePath)
        guard !json else {
            CLIOut.json(
                .object([
                    "action": .string(operation.rawValue), "path": .string(result.path),
                    "title": .string(track.title), "favourite": .bool(result.isFavourite),
                    "changed": .bool(result.changed),
                ]))
            return
        }
        CLIOut.out(
            result.changed
                ? "\(result.isFavourite ? "favourited" : "unfavourited") \(track.title)"
                : "\(track.title) is already \(result.isFavourite ? "a favourite" : "not a favourite")"
        )
    }
}

struct MusicFavoriteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorite", abstract: "Add a track to favourites.", aliases: ["favourite"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Track path, or enough of its name to be unambiguous.") var track: String
    func run() async throws {
        try await execute { try MusicFavouriteBridge.run(.favorite, query: track, json: json) }
    }
}

struct MusicUnfavoriteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unfavorite", abstract: "Remove a track from favourites.",
        aliases: ["unfavourite"])
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Track path, or enough of its name to be unambiguous.") var track: String
    func run() async throws {
        try await execute { try MusicFavouriteBridge.run(.unfavorite, query: track, json: json) }
    }
}

struct MusicRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal", abstract: "Reveal a track in Finder.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    @Argument(help: "Track path, or enough of its name to be unambiguous.") var track: String
    func run() async throws {
        try await execute {
            let found = try LibraryBridge.track(track)
            let url = await MusicLibraryOperationExecution.reveal(found.url)
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("reveal"), "path": .string(found.relativePath),
                        "file": .string(url.path), "opened": .bool(true),
                    ]))
                return
            }
            CLIOut.out("revealed \(found.title)")
        }
    }
}

struct MusicOpenLibraryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open the music library in Finder.")
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
    func run() async throws {
        try await execute {
            let url = try await MusicLibraryOperationExecution.openLibrary()
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("open"), "path": .string(url.path),
                        "opened": .bool(true),
                    ]))
                return
            }
            CLIOut.out("opened \(url.path)")
        }
    }
}

struct MusicRescanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescan",
        abstract: "Read the music folder again after changing it outside Edith.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try LibraryBridge.requireFolder()
            let tracks = MusicLibraryContentOperationExecution.rescan().count
            LibraryBridge.announce()
            guard !json else {
                CLIOut.json(.object(["tracks": .int(tracks)]))
                return
            }
            CLIOut.out("\(tracks) track(s) in the library")
        }
    }
}
