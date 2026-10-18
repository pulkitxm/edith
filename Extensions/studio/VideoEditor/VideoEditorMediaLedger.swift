import Foundation

extension VideoEditorService {
    struct MediaReservation: Codable, Sendable {
        let ledger: String
        let receipt: VideoMediaLibrary.Reservation
    }

    struct MediaReservations: Codable, Sendable {
        let ledger: String
        let total: Int
        let offset: Int
        let limit: Int
        let nextOffset: Int?
        let receipts: [VideoMediaLibrary.Reservation]
    }

    struct MediaRelease: Codable, Sendable {
        let ledger: String
        let token: UUID
        let released: Bool
    }

    static func requireMediaLedger(_ url: URL) throws {
        try require(
            url.isFileURL && url.pathExtension == "json", "Ledger must be a local .json file.")
    }

    public static func mediaReserve(_ source: URL, ledger: URL, reelID: String) async throws -> Data
    {
        try await mediaErrors {
            try requireMediaLedger(ledger)
            try require(
                !reelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && reelID.count <= 1000,
                "Reel ID must be 1 to 1000 characters.")
            let lock = try await VideoProjectFileAccess.transaction(source)
            defer { withExtendedLifetime(lock) {} }
            let snapshot = try readProject(source)
            for destination in [ledger, URL(fileURLWithPath: ledger.path + ".lock")] {
                try protectMediaSources(snapshot.project, destination: destination)
                try VideoProjectExportDestination.validate(destination, project: snapshot.project)
            }
            return try VideoProjectFileAccess.publication(source) {
                try verifyMediaRevision(snapshot.revision)
                var report: Data?
                _ = try snapshot.project.reserveOriginalMedia(
                    in: .init(url: ledger), reelID: reelID,
                    validateReceipt: { receipt in
                        try verifyMediaRevision(snapshot.revision)
                        let data = try mediaEnvelope(
                            MediaReservation(
                                ledger: ledger.standardizedFileURL.path, receipt: receipt),
                            operation: "reserve", project: source, written: true)
                        try require(data.count < 1024 * 1024, "Reservation receipt exceeds 1 MiB.")
                        report = data
                    })
                return report!
            }
        }
    }

    public static func mediaReservations(_ ledger: URL, offset: Int = 0, limit: Int = 100)
        async throws -> Data
    {
        try await mediaErrors {
            try requireMediaLedger(ledger)
            try require(
                offset >= 0 && (1...100).contains(limit),
                "Offset must be nonnegative and limit must be 1 to 100.")
            let receipts = try VideoMediaLibrary.Ledger(url: ledger).reservations()
            let next =
                offset < receipts.count && receipts.count - offset > limit ? offset + limit : nil
            return try mediaEnvelope(
                MediaReservations(
                    ledger: ledger.standardizedFileURL.path,
                    total: receipts.count, offset: offset, limit: limit, nextOffset: next,
                    receipts: Array(receipts.dropFirst(offset).prefix(limit))),
                operation: "reservations")
        }
    }

    public static func mediaRelease(_ ledger: URL, receiptFile: URL) async throws -> Data {
        try await mediaErrors {
            try requireMediaLedger(ledger)
            try requireLocalFile(receiptFile)
            let size = try receiptFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            try require(size <= 1024 * 1024, "Receipt exceeds 1 MiB.")
            let handle = try FileHandle(forReadingFrom: receiptFile)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            let reservation = try decodeMediaReceipt(data)
            let receiptLedger = URL(fileURLWithPath: reservation.ledger)
            try require(
                VideoProjectFileAccess.identity(receiptLedger)
                    == VideoProjectFileAccess.identity(ledger),
                "Receipt belongs to a different ledger.")
            let report = try mediaEnvelope(
                MediaRelease(
                    ledger: ledger.standardizedFileURL.path,
                    token: reservation.receipt.token, released: true), operation: "release",
                written: true)
            try VideoMediaLibrary.Ledger(url: ledger).release(reservation.receipt)
            return report
        }
    }

    static func decodeMediaReceipt(_ data: Data) throws -> MediaReservation {
        try require(data.count <= 1024 * 1024, "Receipt exceeds 1 MiB.")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(root.keys) == ["version", "operation", "project", "written", "result"],
            let result = root["result"] as? [String: Any],
            Set(result.keys) == ["ledger", "receipt"],
            let receipt = result["receipt"] as? [String: Any],
            Set(receipt.keys) == ["token", "reelID", "keys"]
        else { throw Failure("invalid_receipt", "Expected an unmodified reserve result envelope.") }
        let value = try JSONDecoder().decode(MediaEnvelope<MediaReservation>.self, from: data)
        try require(
            value.version == 1 && value.operation == "reserve" && value.written
                && value.project != nil,
            "Expected a version 1 successful reserve result.")
        try require(
            value.result.ledger.hasPrefix("/") && !value.result.receipt.keys.isEmpty
                && value.result.receipt.keys.count == Set(value.result.receipt.keys).count,
            "Receipt ledger must be absolute and receipt keys must be unique and nonempty.")
        return value.result
    }
}
