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
        var captureDate: CaptureDate = .init(
            source: nil, rawValues: [], utc: nil, timezone: .unknown, offsetMinutes: nil)
    }

    struct CaptureDate: Codable, Equatable, Sendable {
        enum Timezone: String, Codable, Sendable {
            case explicitOffset, unknown, invalid, conflicting
        }
        let source: String?
        let rawValues: [String]
        let utc: String?
        let timezone: Timezone
        let offsetMinutes: Int?
        let isOriginalMetadata: Bool

        init(
            source: String?, rawValues: [String], utc: String?, timezone: Timezone,
            offsetMinutes: Int?
        ) {
            self.source = source
            self.rawValues = rawValues
            self.utc = utc
            self.timezone = timezone
            self.offsetMinutes = offsetMinutes
            isOriginalMetadata =
                source == "exif.DateTimeOriginal"
                || source?.contains("original_creation_time") == true
        }
    }

    private static let captureDateKeys = [
        "mdta/com.apple.quicktime.original_creation_time", "mdta/original_creation_time",
        AVMetadataIdentifier.quickTimeMetadataCreationDate.rawValue,
        AVMetadataIdentifier.quickTimeUserDataCreationDate.rawValue,
        AVMetadataIdentifier.commonIdentifierCreationDate.rawValue,
    ]

    static func captureDate(
        exif: [String: Any] = [:], quickTime: [String: [String]] = [:]
    ) -> CaptureDate {
        if let original = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            return parseCaptureDate(
                original, offset: exif["OffsetTimeOriginal"] as? String,
                source: "exif.DateTimeOriginal")
        }
        for key in captureDateKeys {
            let values = Array(Set(quickTime[key] ?? [])).sorted()
            if values.count > 1 {
                return .init(
                    source: key, rawValues: values, utc: nil, timezone: .conflicting,
                    offsetMinutes: nil)
            }
            if let value = values.first { return parseCaptureDate(value, source: key) }
        }
        if let digitized = exif[kCGImagePropertyExifDateTimeDigitized as String] as? String {
            return parseCaptureDate(
                digitized, offset: exif["OffsetTimeDigitized"] as? String,
                source: "exif.DateTimeDigitized")
        }
        return .init(source: nil, rawValues: [], utc: nil, timezone: .unknown, offsetMinutes: nil)
    }

    private static func parseCaptureDate(_ raw: String, offset: String? = nil, source: String)
        -> CaptureDate
    {
        let rawValues = [raw] + (offset.map { [$0] } ?? [])
        func result(_ timezone: CaptureDate.Timezone, utc: String? = nil, minutes: Int? = nil)
            -> CaptureDate
        {
            .init(
                source: source, rawValues: rawValues, utc: utc, timezone: timezone,
                offsetMinutes: minutes)
        }
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if source.hasPrefix("exif."), value.count >= 10 {
            value = value.prefix(10).replacingOccurrences(of: ":", with: "-") + value.dropFirst(10)
        }
        let expression = try! NSRegularExpression(
            pattern: #"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:?\d{2})?$"#)
        guard
            let match = expression.firstMatch(
                in: value, range: NSRange(value.startIndex..., in: value))
        else { return result(.invalid) }
        func group(_ index: Int) -> String {
            Range(match.range(at: index), in: value).map { String(value[$0]) } ?? ""
        }
        let local = group(1) + "T" + group(2)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: local), formatter.string(from: date) == local else {
            return result(.invalid)
        }
        let zone = offset ?? group(4)
        if let offset, !group(4).isEmpty, offset != group(4) { return result(.conflicting) }
        if zone.isEmpty || zone == "-00:00" || zone == "-0000" { return result(.unknown) }
        let minutes: Int
        if zone == "Z" {
            minutes = 0
        } else {
            guard zone.range(of: #"^[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil else {
                return result(.invalid)
            }
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let hours = Int(digits.prefix(2)), let remainder = Int(digits.suffix(2)),
                hours <= 14, remainder < 60, hours != 14 || remainder == 0
            else { return result(.invalid) }
            minutes = (hours * 60 + remainder) * (zone.hasPrefix("-") ? -1 : 1)
        }
        let fraction = Double("0" + group(3)) ?? 0
        let utc = date.addingTimeInterval(fraction - Double(minutes * 60))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return result(.explicitOffset, utc: iso.string(from: utc), minutes: minutes)
    }

    static func chronologicalOrder(_ media: [InspectedMedia]) -> [InspectedMedia] {
        media.sorted {
            let left = $0.metadata.captureDate.utc
            let right = $1.metadata.captureDate.utc
            if left != right { return (left ?? "~") < (right ?? "~") }
            if $0.source.identity.sha256 != $1.source.identity.sha256 {
                return $0.source.identity.sha256 < $1.source.identity.sha256
            }
            return $0.url.absoluteString < $1.url.absoluteString
        }
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
            case .identityMismatch(let path):
                return "Media content identity does not match: \(path)"
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
            groups[try identity(of: url, checkCancellation: checkCancellation), default: []].append(
                url)
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
                    orientation: properties[kCGImagePropertyOrientation as String] as? Int ?? 1),
                captureDate: captureDate(
                    exif: properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
                        ?? [:]))
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var video: [VideoTrack] = []
        for track in try await asset.loadTracks(withMediaType: .video) {
            try Task.checkCancellation()
            let (size, transform, fps, formats) = try await track.load(
                .naturalSize, .preferredTransform, .nominalFrameRate, .formatDescriptions)
            let display = CGRect(origin: .zero, size: size).applying(transform).standardized.size
            video.append(
                VideoTrack(
                    codecs: formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) },
                    width: size.width, height: size.height,
                    displayWidth: display.width, displayHeight: display.height,
                    transform: [
                        transform.a, transform.b, transform.c, transform.d, transform.tx,
                        transform.ty,
                    ],
                    nominalFrameRate: Double(fps)))
        }
        var audio: [AudioTrack] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            try Task.checkCancellation()
            for format in try await track.load(.formatDescriptions) {
                guard
                    let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?
                        .pointee
                else { continue }
                audio.append(
                    AudioTrack(
                        codec: fourCC(description.mFormatID), sampleRate: description.mSampleRate,
                        channels: description.mChannelsPerFrame))
            }
        }
        guard !video.isEmpty || !audio.isEmpty else { throw Failure.unsupportedMedia(url.path) }
        var dates: [String: [String]] = [:]
        var items = try await asset.load(.commonMetadata)
        for format in try await asset.load(.availableMetadataFormats) {
            items += try await asset.loadMetadata(for: format)
        }
        for item in items {
            try Task.checkCancellation()
            if let key = item.identifier?.rawValue, captureDateKeys.contains(key),
                let value = try await item.load(.stringValue)
            {
                dates[key, default: []].append(value)
            }
        }
        try Task.checkCancellation()
        return Metadata(
            duration: duration.isFinite ? duration : nil, video: video, audio: audio, image: nil,
            captureDate: captureDate(quickTime: dates))
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
        var currentPath = stat()
        guard stat(url.path, &currentPath) == 0,
            currentPath.st_dev == after.st_dev, currentPath.st_ino == after.st_ino
        else { throw Failure.changedDuringRead(url.path) }
        guard count == before.st_size, before.st_size == after.st_size,
            before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
            before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
        else { throw Failure.changedDuringRead(url.path) }
        try checkCancellation()
        return Identity(
            sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), byteCount: count)
    }

    fileprivate static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    fileprivate static func copy(
        _ source: URL, to destination: URL, expected: Identity,
        checkCancellation: () throws -> Void
    ) throws {
        let descriptor = Darwin.open(
            destination.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: destination) }
        }
        let actual = try stream(source, checkCancellation: checkCancellation) { data in
            try output.write(contentsOf: data)
        }
        guard actual == expected else { throw Failure.identityMismatch(source.path) }
        try output.synchronize()
        try output.close()
        complete = true
    }

    enum Role: String, Codable, Sendable {
        case original
        case camera
        case sourceImage
        case processedAudio
        case cursor
        case wallpaper
        case annotationImage
        case annotationContent
    }

    struct Reference: Codable, Hashable, Sendable {
        let assetID: String
        let role: Role
    }

    struct Entry: Codable, Equatable, Sendable {
        let reference: Reference
        let source: Source
        var metadata: Metadata?
        var packagedPath: String?
    }

    struct Manifest: Codable, Equatable, Sendable {
        var version = 1
        var entries: [Entry]
    }

    enum RelinkPolicy: String, Codable, Sendable {
        case requireIdentity
        case allowReplacement
    }

    struct RelinkResult: Codable, Equatable, Sendable {
        let reference: Reference
        let previousURL: URL
        let url: URL
        let previousIdentity: Identity?
        let identity: Identity
        let contentChanged: Bool
    }

    struct PackageResult: Codable, Equatable, Sendable {
        let directory: URL
        let projectURL: URL
        let copiedFileCount: Int
        let copiedByteCount: Int64
        let manifest: Manifest
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

            func validate() throws {
                guard version == 1 else { throw Failure.invalidLedger }
                for (hash, family) in families {
                    try Identity(sha256: hash, byteCount: 0).validate()
                    guard !family.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw Failure.invalidLedger
                    }
                }
                for (key, receipt) in reservations {
                    guard !receipt.reelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        receipt.keys.contains(key), Set(receipt.keys).count == receipt.keys.count,
                        receipt.keys.allSatisfy({ reservations[$0] == receipt })
                    else { throw Failure.invalidLedger }
                    if key.hasPrefix("sha256:") {
                        let hash = String(key.dropFirst(7))
                        try Identity(sha256: hash, byteCount: 0).validate()
                        if let family = families[hash], reservations["family:\(family)"] != receipt
                        {
                            throw Failure.invalidLedger
                        }
                    } else if key.hasPrefix("family:") {
                        guard
                            families.contains(where: {
                                $0.value == String(key.dropFirst(7))
                                    && reservations["sha256:\($0.key)"] == receipt
                            })
                        else { throw Failure.invalidLedger }
                    } else {
                        throw Failure.invalidLedger
                    }
                }
            }
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
                                throw Failure.reservationConflict(
                                    key: "family:\(family)", reelID: owner.reelID)
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
            try transaction(write: false, checkCancellation: { try Task.checkCancellation() }) {
                state in
                Dictionary(grouping: state.reservations.values, by: \.token).values.compactMap(
                    \.first
                )
                .sorted { $0.token.uuidString < $1.token.uuidString }
            }
        }

        private func transaction<T>(
            write: Bool = true, checkCancellation: () throws -> Void,
            operation: (inout State) throws -> T
        ) throws -> T {
            guard url.isFileURL else { throw Failure.invalidLedger }
            let directory = url.deletingLastPathComponent().resolvingSymlinksInPath()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(url.lastPathComponent)
            let lock = Darwin.open(
                target.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw posixError() }
            defer { Darwin.close(lock) }
            while flock(lock, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK || errno == EINTR else { throw posixError() }
                try checkCancellation()
                usleep(10_000)
            }
            defer { flock(lock, LOCK_UN) }
            try checkCancellation()
            var state = try readState(at: target)
            try state.validate()
            let result = try operation(&state)
            try checkCancellation()
            if write {
                try state.validate()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(state).write(to: target, options: .atomic)
            }
            return result
        }

        private func readState(at target: URL) throws -> State {
            let descriptor = Darwin.open(
                target.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else {
                if errno == ENOENT { return State() }
                if errno == ELOOP { throw Failure.invalidLedger }
                throw posixError()
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw posixError() }
            guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidLedger }
            return try JSONDecoder().decode(State.self, from: handle.readToEnd() ?? Data())
        }
    }
}

extension VideoProject {
    func mediaReferences() throws -> [VideoMediaLibrary.Reference] {
        var ids = Set<String>()
        var result: [VideoMediaLibrary.Reference] = []
        let recorded = try mediaManifest().entries.map(\.reference)
        for asset in assets {
            guard !asset.id.isEmpty, ids.insert(asset.id).inserted else {
                throw VideoMediaLibrary.Failure.invalidReference(asset.id)
            }
            result.append(.init(assetID: asset.id, role: .original))
            if asset.cameraTrack != nil { result.append(.init(assetID: asset.id, role: .camera)) }
            if asset.raw["edithSourceImagePath"] != nil {
                result.append(.init(assetID: asset.id, role: .sourceImage))
            }
            if asset.raw["edithAudioPath"] != nil {
                result.append(.init(assetID: asset.id, role: .processedAudio))
            }
            let cursor = VideoMediaLibrary.Reference(assetID: asset.id, role: .cursor)
            if try recorded.contains(cursor)
                || FileManager.default.fileExists(atPath: mediaURL(for: cursor).path)
            {
                result.append(cursor)
            }
        }
        if Self.externalImagePath(backgroundColor) != nil {
            result.append(.init(assetID: id, role: .wallpaper))
        }
        var annotationIDs = Set<String>()
        for annotation in annotations where annotation.type == "image" {
            guard !annotation.id.isEmpty, annotationIDs.insert(annotation.id).inserted else {
                throw VideoMediaLibrary.Failure.invalidReference(annotation.id)
            }
            for (key, role) in [
                ("imageContent", VideoMediaLibrary.Role.annotationImage),
                ("content", .annotationContent),
            ] {
                if let value = annotation.raw[key] as? String, Self.externalImagePath(value) != nil
                {
                    result.append(.init(assetID: annotation.id, role: role))
                }
            }
        }
        return result
    }

    func mediaURL(for reference: VideoMediaLibrary.Reference) throws -> URL {
        let asset = assets.first(where: { $0.id == reference.assetID })
        let path: String?
        switch reference.role {
        case .original: path = asset?.raw["originalPath"] as? String
        case .camera: path = asset?.cameraTrack?["sourcePath"] as? String
        case .sourceImage: path = asset?.raw["edithSourceImagePath"] as? String
        case .processedAudio: path = asset?.raw["edithAudioPath"] as? String
        case .cursor:
            return URL(
                fileURLWithPath: try mediaURL(
                    for: .init(assetID: reference.assetID, role: .original)
                ).path + ".cursor.json")
        case .wallpaper:
            guard reference.assetID == id else {
                throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
            }
            path = Self.externalImagePath(backgroundColor)
        case .annotationImage, .annotationContent:
            let key = reference.role == .annotationImage ? "imageContent" : "content"
            path = (annotations.first { $0.id == reference.assetID }?.raw[key] as? String)
                .flatMap(Self.externalImagePath)
        }
        guard let path, !path.isEmpty else {
            throw VideoMediaLibrary.Failure.invalidReference(
                "\(reference.assetID):\(reference.role.rawValue)")
        }
        if (path as NSString).isAbsolutePath { return URL(fileURLWithPath: path) }
        guard let fileURL else { throw VideoMediaLibrary.Failure.invalidReference(path) }
        return fileURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    private static func externalImagePath(_ value: String) -> String? {
        let lower = value.lowercased()
        guard !value.isEmpty, !value.hasPrefix("#"), !lower.hasPrefix("data:"),
            !lower.hasPrefix("http:"), !lower.hasPrefix("https:")
        else { return nil }
        if lower.hasPrefix("file:"), let url = URL(string: value), url.isFileURL { return url.path }
        let imageExtensions = [
            "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "gif", "bmp", "avif",
            "svg",
        ]
        return (value as NSString).isAbsolutePath || value.contains("/")
            || imageExtensions.contains((value as NSString).pathExtension.lowercased())
            ? value : nil
    }

    func mediaManifest() throws -> VideoMediaLibrary.Manifest {
        guard let raw = root["edithMediaLibrary"] else { return .init(entries: []) }
        let manifest = try JSONDecoder().decode(
            VideoMediaLibrary.Manifest.self, from: JSONSerialization.data(withJSONObject: raw))
        guard manifest.version == 1,
            Set(manifest.entries.map(\.reference)).count == manifest.entries.count
        else { throw VideoMediaLibrary.Failure.invalidReference("media manifest") }
        for entry in manifest.entries {
            try entry.source.identity.validate()
            try entry.source.provenance?.validate()
        }
        return manifest
    }

    @discardableResult
    mutating func indexMedia(
        provenanceByAssetID: [String: VideoMediaLibrary.Provenance] = [:],
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VideoMediaLibrary.Manifest {
        let existing = try mediaManifest()
        guard Set(provenanceByAssetID.keys).isSubset(of: Set(assets.map(\.id))) else {
            throw VideoMediaLibrary.Failure.invalidReference("provenance asset IDs")
        }
        var entries: [VideoMediaLibrary.Entry] = []
        for reference in try mediaReferences() {
            let url = try mediaURL(for: reference)
            let identity = try VideoMediaLibrary.identity(
                of: url, checkCancellation: checkCancellation)
            let previous = existing.entries.first { $0.reference == reference }
            if let expected = previous?.source.identity, expected != identity {
                throw VideoMediaLibrary.Failure.identityMismatch(url.path)
            }
            let provenance =
                reference.role == .original
                ? provenanceByAssetID[reference.assetID] ?? previous?.source.provenance
                : previous?.source.provenance
            try provenance?.validate()
            if let previousFamily = previous?.source.provenance?.sourceFamilyID,
                provenance?.sourceFamilyID != previousFamily
            {
                throw VideoMediaLibrary.Failure.provenanceConflict(identity.sha256)
            }
            entries.append(
                .init(
                    reference: reference, source: .init(identity: identity, provenance: provenance),
                    metadata: previous?.metadata, packagedPath: previous?.packagedPath))
        }
        let manifest = VideoMediaLibrary.Manifest(entries: entries)
        try checkCancellation()
        try setMediaManifest(manifest)
        return manifest
    }

    @discardableResult
    mutating func inspectMedia() async throws -> VideoMediaLibrary.Manifest {
        var candidate = self
        var manifest = try candidate.indexMedia()
        for index in manifest.entries.indices {
            if manifest.entries[index].reference.role == .cursor { continue }
            let url = try mediaURL(for: manifest.entries[index].reference)
            let inspected = try await VideoMediaLibrary.inspect(
                url, provenance: manifest.entries[index].source.provenance)
            guard inspected.source.identity == manifest.entries[index].source.identity else {
                throw VideoMediaLibrary.Failure.identityMismatch(url.path)
            }
            manifest.entries[index].metadata = inspected.metadata
        }
        try Task.checkCancellation()
        try setMediaManifest(manifest)
        return manifest
    }

    @discardableResult
    mutating func relinkOriginalMedia(
        _ reference: VideoMediaLibrary.Reference, to url: URL,
        policy: VideoMediaLibrary.RelinkPolicy = .requireIdentity,
        expectedIdentity: VideoMediaLibrary.Identity? = nil,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VideoMediaLibrary.RelinkResult {
        let previousURL = try mediaURL(for: reference)
        var manifest = try mediaManifest()
        let previous = manifest.entries.first { $0.reference == reference }
        if let expectedIdentity { try expectedIdentity.validate() }
        if let recorded = previous?.source.identity, let expectedIdentity,
            recorded != expectedIdentity
        {
            throw VideoMediaLibrary.Failure.identityMismatch(previousURL.path)
        }
        var expected = expectedIdentity ?? previous?.source.identity
        if expected == nil, policy == .requireIdentity {
            expected = try VideoMediaLibrary.identity(
                of: previousURL, checkCancellation: checkCancellation)
        }
        let actual = try VideoMediaLibrary.identity(of: url, checkCancellation: checkCancellation)
        if policy == .requireIdentity, expected != actual {
            throw VideoMediaLibrary.Failure.identityMismatch(url.path)
        }
        let changed = expected != actual
        if reference.role == .original {
            let cursor = VideoMediaLibrary.Reference(assetID: reference.assetID, role: .cursor)
            if changed {
                manifest.entries.removeAll {
                    $0.reference.assetID == reference.assetID
                        && [.cursor, .processedAudio].contains($0.reference.role)
                }
            } else {
                let oldCursor = URL(fileURLWithPath: previousURL.path + ".cursor.json")
                let recorded = manifest.entries.first { $0.reference == cursor }
                let identity =
                    try recorded?.source.identity
                    ?? (FileManager.default.fileExists(atPath: oldCursor.path)
                        ? VideoMediaLibrary.identity(
                            of: oldCursor, checkCancellation: checkCancellation) : nil)
                let cursorURL = URL(fileURLWithPath: url.path + ".cursor.json")
                if let identity {
                    guard
                        try VideoMediaLibrary.identity(
                            of: cursorURL, checkCancellation: checkCancellation) == identity
                    else { throw VideoMediaLibrary.Failure.identityMismatch(cursorURL.path) }
                    if recorded == nil {
                        manifest.entries.append(
                            .init(reference: cursor, source: .init(identity: identity)))
                    }
                } else if policy == .requireIdentity,
                    FileManager.default.fileExists(atPath: cursorURL.path)
                {
                    throw VideoMediaLibrary.Failure.identityMismatch(cursorURL.path)
                }
            }
        }
        manifest.entries.removeAll { $0.reference == reference }
        manifest.entries.append(
            .init(
                reference: reference,
                source: .init(
                    identity: actual, provenance: changed ? nil : previous?.source.provenance),
                metadata: changed ? nil : previous?.metadata, packagedPath: nil))
        var candidate = self
        try candidate.setMediaURL(url, for: reference)
        if reference.role == .original, changed {
            var entries = candidate.assets.map(\.raw)
            for index in entries.indices where entries[index]["id"] as? String == reference.assetID
            {
                entries[index].removeValue(forKey: "edithAudioPath")
            }
            candidate.root["assets"] = entries
        }
        try candidate.setMediaManifest(manifest)
        try checkCancellation()
        self = candidate
        return .init(
            reference: reference, previousURL: previousURL, url: url, previousIdentity: expected,
            identity: actual, contentChanged: changed)
    }

    func reserveOriginalMedia(
        in ledger: VideoMediaLibrary.Ledger, reelID: String,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VideoMediaLibrary.Reservation {
        var candidate = self
        let manifest = try candidate.indexMedia(checkCancellation: checkCancellation)
        let usedAssetIDs = Set(clips.map(\.assetID) + audioTracks.map(\.assetID))
        guard usedAssetIDs.isSubset(of: Set(assets.map(\.id))) else {
            throw VideoMediaLibrary.Failure.invalidReference("timeline media asset IDs")
        }
        let sourceRoles: Set<VideoMediaLibrary.Role> = [
            .original, .camera, .sourceImage, .processedAudio,
        ]
        let sources = manifest.entries.filter {
            sourceRoles.contains($0.reference.role) && usedAssetIDs.contains($0.reference.assetID)
        }.map(\.source)
        return try ledger.reserve(sources, reelID: reelID, checkCancellation: checkCancellation)
    }

    func packageOriginalMedia(
        to destination: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VideoMediaLibrary.PackageResult {
        guard destination.isFileURL else {
            throw VideoMediaLibrary.Failure.invalidReference(destination.absoluteString)
        }
        let manager = FileManager.default
        let parent = destination.deletingLastPathComponent().resolvingSymlinksInPath()
        let target = parent.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        guard !manager.fileExists(atPath: target.path) else {
            throw VideoMediaLibrary.Failure.destinationExists(target.path)
        }
        var candidate = self
        var manifest = try candidate.indexMedia(checkCancellation: checkCancellation)
        let stage = parent.appendingPathComponent(".media-stage-\(UUID())", isDirectory: true)
        try manager.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: stage) }
        try manager.createDirectory(
            at: stage.appendingPathComponent("originals"), withIntermediateDirectories: false)
        var paths: [VideoMediaLibrary.Reference: String] = [:]
        for entry in manifest.entries where entry.reference.role != .cursor {
            let suffix = try mediaURL(for: entry.reference).pathExtension.lowercased()
            let safeSuffix =
                !suffix.isEmpty && suffix.count <= 16
                && suffix.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let cursor = manifest.entries.first {
                entry.reference.role == .original && $0.reference.role == .cursor
                    && $0.reference.assetID == entry.reference.assetID
            }
            let association = cursor.map { "-cursor-\($0.source.identity.sha256)" } ?? ""
            paths[entry.reference] =
                "originals/\(entry.source.identity.sha256)\(association)"
                + (safeSuffix ? ".\(suffix)" : "")
        }
        for entry in manifest.entries where entry.reference.role == .cursor {
            guard let video = paths[.init(assetID: entry.reference.assetID, role: .original)] else {
                throw VideoMediaLibrary.Failure.invalidReference("cursor source")
            }
            paths[entry.reference] = video + ".cursor.json"
        }
        var copied: [String: VideoMediaLibrary.Identity] = [:]
        for index in manifest.entries.indices {
            try checkCancellation()
            let entry = manifest.entries[index]
            let sourceURL = try mediaURL(for: entry.reference)
            guard let relative = paths[entry.reference] else {
                throw VideoMediaLibrary.Failure.invalidReference("package path")
            }
            if let existing = copied[relative] {
                guard existing == entry.source.identity else {
                    throw VideoMediaLibrary.Failure.identityMismatch(sourceURL.path)
                }
            } else {
                try VideoMediaLibrary.copy(
                    sourceURL, to: stage.appendingPathComponent(relative),
                    expected: entry.source.identity,
                    checkCancellation: checkCancellation)
                copied[relative] = entry.source.identity
            }
            manifest.entries[index].packagedPath = relative
            try candidate.setMediaURL(target.appendingPathComponent(relative), for: entry.reference)
        }
        try candidate.setMediaManifest(manifest)
        try candidate.save(to: stage.appendingPathComponent("project.openscreen"))
        try checkCancellation()
        guard renamex_np(stage.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            if errno == EEXIST { throw VideoMediaLibrary.Failure.destinationExists(target.path) }
            throw VideoMediaLibrary.posixError()
        }
        return .init(
            directory: target, projectURL: target.appendingPathComponent("project.openscreen"),
            copiedFileCount: copied.count,
            copiedByteCount: copied.values.reduce(0) { $0 + $1.byteCount },
            manifest: manifest)
    }

    static func openMediaPackage(
        _ directory: URL,
        checkCancellation: () throws -> Void = { try Task.checkCancellation() }
    ) throws -> VideoProject {
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        var project = try open(base.appendingPathComponent("project.openscreen"))
        let manifest = try project.mediaManifest()
        guard project.root["edithMediaLibrary"] != nil,
            Set(try project.mediaReferences()) == Set(manifest.entries.map(\.reference))
        else { throw VideoMediaLibrary.Failure.invalidReference("incomplete package manifest") }
        for entry in manifest.entries.sorted(by: {
            $0.reference.role != .cursor && $1.reference.role == .cursor
        }) {
            guard let relative = entry.packagedPath,
                relative.hasPrefix("originals/"), relative.split(separator: "/").count == 2,
                !relative.contains("..")
            else { throw VideoMediaLibrary.Failure.invalidReference("package path") }
            let url = base.appendingPathComponent(relative).resolvingSymlinksInPath()
                .standardizedFileURL
            guard url.path.hasPrefix(base.path + "/originals/") else {
                throw VideoMediaLibrary.Failure.invalidReference(relative)
            }
            guard
                try VideoMediaLibrary.identity(of: url, checkCancellation: checkCancellation)
                    == entry.source.identity
            else { throw VideoMediaLibrary.Failure.identityMismatch(url.path) }
            try project.setMediaURL(url, for: entry.reference)
        }
        try checkCancellation()
        return project
    }

    private mutating func setMediaManifest(_ manifest: VideoMediaLibrary.Manifest) throws {
        root["edithMediaLibrary"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(manifest))
    }

    private mutating func setMediaURL(_ url: URL, for reference: VideoMediaLibrary.Reference) throws
    {
        switch reference.role {
        case .cursor:
            guard try mediaURL(for: reference).standardizedFileURL == url.standardizedFileURL else {
                throw VideoMediaLibrary.Failure.invalidReference("cursor association")
            }
            return
        case .wallpaper:
            guard reference.assetID == id else {
                throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
            }
            backgroundColor = url.path
            return
        case .annotationImage, .annotationContent:
            var entries = annotations.map(\.raw)
            guard
                let index = entries.firstIndex(where: { $0["id"] as? String == reference.assetID })
            else {
                throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
            }
            entries[index][reference.role == .annotationImage ? "imageContent" : "content"] =
                url.path
            root["annotations"] = entries
            return
        default: break
        }
        var entries = assets.map(\.raw)
        guard let index = entries.firstIndex(where: { $0["id"] as? String == reference.assetID })
        else {
            throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
        }
        switch reference.role {
        case .original: entries[index]["originalPath"] = url.path
        case .sourceImage: entries[index]["edithSourceImagePath"] = url.path
        case .processedAudio: entries[index]["edithAudioPath"] = url.path
        case .camera:
            guard var camera = entries[index]["cameraTrack"] as? [String: Any] else {
                throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
            }
            camera["sourcePath"] = url.path
            entries[index]["cameraTrack"] = camera
        case .cursor, .wallpaper, .annotationImage, .annotationContent:
            throw VideoMediaLibrary.Failure.invalidReference(reference.assetID)
        }
        root["assets"] = entries
    }
}
