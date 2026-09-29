import AVFoundation
import CryptoKit
import Darwin
import Foundation
import ImageIO

enum VideoMediaLibrary {
    struct Identity: Codable, Hashable, Sendable {
        let sha256: String
        let byteCount: Int64

        func validate() throws {
            guard sha256.count == 64,
                sha256.allSatisfy({ "0123456789abcdef".contains($0) }), byteCount >= 0
            else { throw Failure.invalidIdentity }
        }
    }

    struct Provenance: Codable, Equatable, Sendable {
        let sourceFamilyID: String
        let declaration: String

        func validate() throws {
            guard !sourceFamilyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                !declaration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure.invalidProvenance }
        }
    }

    struct Source: Codable, Equatable, Sendable {
        let identity: Identity
        let provenance: Provenance?

        init(identity: Identity, provenance: Provenance? = nil) {
            self.identity = identity
            self.provenance = provenance
        }
    }

    struct VideoTrack: Codable, Equatable, Sendable {
        let codecs: [String]
        let width: Double
        let height: Double
        let displayWidth: Double
        let displayHeight: Double
        let transform: [Double]
        let nominalFrameRate: Double
    }

    struct AudioTrack: Codable, Equatable, Sendable {
        let codec: String
        let sampleRate: Double
        let channels: UInt32
    }

    struct Image: Codable, Equatable, Sendable {
        let type: String
        let width: Int
        let height: Int
        let orientation: Int
    }

    struct Metadata: Codable, Equatable, Sendable {
        let duration: Double?
        let video: [VideoTrack]
        let audio: [AudioTrack]
        let image: Image?
    }

    struct InspectedMedia: Codable, Equatable, Sendable {
        let url: URL
        let source: Source
        let metadata: Metadata
    }

    struct DuplicateGroup: Codable, Equatable, Sendable {
        let identity: Identity
        let urls: [URL]
    }

    enum Failure: Error, LocalizedError, Equatable {
        case invalidIdentity
        case invalidProvenance
        case invalidReference(String)
        case notRegularFile(String)
        case changedDuringRead(String)
        case identityMismatch(String)
        case unsupportedMedia(String)
        case reservationConflict(key: String, reelID: String)
        case provenanceConflict(String)
        case invalidReceipt
        case invalidLedger
        case destinationExists(String)

        var errorDescription: String? {
            switch self {
            case .invalidIdentity: return "Invalid SHA-256 media identity."
            case .invalidProvenance: return "Source family and explicit provenance are required."
            case .invalidReference(let value): return "Invalid media reference: \(value)"
            case .notRegularFile(let path): return "Media must be a regular local file: \(path)"
            case .changedDuringRead(let path): return "Media changed while reading: \(path)"
            case .identityMismatch(let path): return "Media content identity does not match: \(path)"
            case .unsupportedMedia(let path): return "No supported media tracks or image: \(path)"
            case .reservationConflict(let key, let reel):
                return "Source \(key) is already reserved by reel \(reel)."
            case .provenanceConflict(let hash): return "Conflicting source family for \(hash)."
            case .invalidReceipt: return "Reservation receipt does not own all requested sources."
            case .invalidLedger: return "Invalid media reservation ledger."
            case .destinationExists(let path): return "Destination already exists: \(path)"
            }
        }
    }

    static func identity(
        of url: URL, checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> Identity {
        try stream(url, checkCancellation: checkCancellation) { _ in }
    }

    static func duplicates(
        in urls: [URL], checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> [DuplicateGroup] {
        var groups: [Identity: [URL]] = [:]
        for url in Set(urls).sorted(by: { $0.path < $1.path }) {
            groups[try identity(of: url, checkCancellation: checkCancellation), default: []].append(url)
        }
        return groups.filter { $0.value.count > 1 }.map {
            DuplicateGroup(identity: $0.key, urls: $0.value)
        }.sorted { $0.identity.sha256 < $1.identity.sha256 }
    }

    static func inspect(_ url: URL, provenance: Provenance? = nil) async throws -> InspectedMedia {
        try provenance?.validate()
        let before = try identity(of: url)
        let metadata = try await probe(url)
        guard try identity(of: url) == before else { throw Failure.changedDuringRead(url.path) }
        return InspectedMedia(
            url: url, source: Source(identity: before, provenance: provenance), metadata: metadata)
    }

    static func probe(_ url: URL) async throws -> Metadata {
        try Task.checkCancellation()
        let handle = try openRegularFile(url)
        try handle.close()
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            let type = CGImageSourceGetType(source)
        {
            return Metadata(
                duration: nil, video: [], audio: [],
                image: Image(
                    type: type as String, width: width, height: height,
                    orientation: properties[kCGImagePropertyOrientation as String] as? Int ?? 1))
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var video: [VideoTrack] = []
        for track in try await asset.loadTracks(withMediaType: .video) {
            try Task.checkCancellation()
            let (size, transform, fps, formats) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            video.append(VideoTrack(
                codecs: formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                width: size.width, height: size.height,
                displayWidth: display.width, displayHeight: display.height,
                transform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
                nominalFrameRate: Double(fps)))
        }
        var audio: [AudioTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            try Task.checkCancellation()
            for format in try await track.load(.formatDescriptions) {
                guard let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
                else { continue }
                audio.append(AudioTrack(
                    codec: fourCC(description.mFormatID), sampleRate: description.mSampleRate,
                    channels: description.mChannelsPerFrame))
            }
        }
        guard !video.isEmpty || !audio.isEmpty else { throw Failure.unsupportedMedia(url.path) }
        try Task.checkCancellation()
        return Metadata(duration: duration.isFinite ? duration : nil, video: video, audio: audio, image: nil)
    }

    private static func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
        return bytes.allSatisfy { (32...126).contains($0) }
            ? String(bytes: bytes, encoding: .ascii)! : String(format: "0x%08x", value)
    }

    private static func openRegularFile(_ url: URL) throws -> FileHandle {
        guard url.isFileURL else { throw Failure.notRegularFile(url.absoluteString) }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile(url.path) }
        return handle
    }

    private static func stream(
        _ url: URL, checkCancellation: () throws -> Void, consume: (Data) throws -> Void
    ) throws -> Identity {
        try checkCancellation()
        let handle = try openRegularFile(url)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(handle.fileDescriptor, &before) == 0 else { throw posixError() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try checkCancellation()
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
            count += Int64(data.count)
            try consume(data)
        }
        var after = stat()
        guard fstat(handle.fileDescriptor, &after) == 0 else { throw posixError() }
        guard count == before.st_size, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw Failure.changedDuringRead(url.path) }
        try checkCancellation()
        return Identity(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count)
    }

    fileprivate static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    struct Reservation: Codable, Equatable, Sendable {
        let token: UUID
        let reelID: String
        let keys: [String]
    }

    struct Ledger: Sendable {
        let url: URL

        private struct State: Codable {
            var version = 1
            var families: [String: String] = [:]
            var reservations: [String: Reservation] = [:]
        }

        func reserve(
            _ sources: [Source], reelID: String,
            checkCancellation: () throws -> Void = { try Task.checkCancellation() }
        ) throws -> Reservation {
            guard !sources.isEmpty, !reelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure.invalidReference(reelID) }
            return try transaction(checkCancellation: checkCancellation) { state in
                for source in sources {
                    try source.identity.validate()
                    try source.provenance?.validate()
                    if let family = source.provenance?.sourceFamilyID {
                        let hash = source.identity.sha256
                        if let known = state.families[hash], known != family {
                            throw Failure.provenanceConflict(hash)
                        }
                        state.families[hash] = family
                    }
                }
                var keys = Set<String>()
                for source in sources {
                    keys.insert("sha256:\(source.identity.sha256)")
                    if let family = state.families[source.identity.sha256] {
                        keys.insert("family:\(family)")
                        for (hash, known) in state.families where known == family {
                            if let owner = state.reservations["sha256:\(hash)"] {
                                throw Failure.reservationConflict(key: "family:\(family)", reelID: owner.reelID)
                            }
                        }
                    }
                }
                for key in keys.sorted() {
                    if let owner = state.reservations[key] {
                        throw Failure.reservationConflict(key: key, reelID: owner.reelID)
                    }
                }
                let receipt = Reservation(token: UUID(), reelID: reelID, keys: keys.sorted())
                for key in keys { state.reservations[key] = receipt }
                return receipt
            }
        }

        func release(
            _ receipt: Reservation,
            checkCancellation: () throws -> Void = { try Task.checkCancellation() }
        ) throws {
            try transaction(checkCancellation: checkCancellation) { state in
                guard !receipt.keys.isEmpty,
                    receipt.keys.allSatisfy({ state.reservations[$0] == receipt })
                else { throw Failure.invalidReceipt }
                for key in receipt.keys { state.reservations.removeValue(forKey: key) }
            }
        }

        func reservations() throws -> [Reservation] {
            try transaction(write: false, checkCancellation: { try Task.checkCancellation() }) { state in
                Dictionary(grouping: state.reservations.values, by: \.token).values.compactMap(\.first)
                    .sorted { $0.token.uuidString < $1.token.uuidString }
            }
        }

        private func transaction<T>(
            write: Bool = true, checkCancellation: () throws -> Void,
            operation: (inout State) throws -> T
        ) throws -> T {
            guard url.isFileURL else { throw Failure.invalidLedger }
            let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(url.lastPathComponent)
            let lock = Darwin.open(target.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw posixError() }
            defer { Darwin.close(lock) }
            while flock(lock, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw posixError() }
                try checkCancellation()
                usleep(10_000)
            }
            defer { flock(lock, LOCK_UN) }
            try checkCancellation()
            var state: State
            do {
                state = try JSONDecoder().decode(State.self, from: Data(contentsOf: target))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                state = State()
            }
            guard state.version == 1 else { throw Failure.invalidLedger }
            let result = try operation(&state)
            try checkCancellation()
            if write {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(state).write(to: target, options: .atomic)
            }
            return result
        }
    }
}
