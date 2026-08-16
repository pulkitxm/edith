import Foundation

public struct CompanionExportMediaItem: Decodable, Sendable {
    public let episodeId: String
    public let uri: String
    public let sha256: String
    public let bytes: Int64
}

public struct CompanionExportManifest: Decodable, Sendable {
    public let format: String
    public let version: Int
    public let counts: [String: Int]
    public let media: [CompanionExportMediaItem]
}

public struct CompanionImportBundleOutcome: Decodable, Sendable {
    public let episodesInserted: Int
    public let episodesSkipped: Int
    public let observationsInserted: Int
    public let conversationsInserted: Int
    public let messagesInserted: Int
    public let beliefsInserted: Int
    public let claimsInserted: Int
    public let claimsSkipped: Int
    public let factsInserted: Int
    public let coreSectionsInserted: Int
    public let settingsInserted: Int
    public let vaultFilesWritten: Int
    public let pendingEpisodes: Int
}

public struct CompanionMediaImportOutcome: Decodable, Sendable {
    public let uri: String
    public let bytes: Int
}

public struct CompanionEpisodeDeletion: Decodable, Sendable {
    public let id: String
    public let claimsDeleted: Int
    public let chunksDeleted: Int
    public let sourceDeleted: Bool
    public let vaultFileRemoved: Bool
}

public struct CompanionWipeOutcome: Decodable, Sendable {
    public let episodesDropped: Int
    public let sourcesDropped: Int
    public let observationsDropped: Int
    public let conversationsDropped: Int
    public let beliefsDropped: Int
    public let vaultCleared: Bool
}

extension CompanionClient {
    public func exportBundle() async throws -> Data {
        var request = URLRequest(url: url(for: "export"))
        request.timeoutInterval = 600
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionClientError.unreachable("the server returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CompanionClientError.badResponse(
                http.statusCode,
                String(decoding: data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    public func importBundle(_ json: Data) async throws -> CompanionImportBundleOutcome {
        var request = URLRequest(url: url(for: "import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        return try await self.request(request, timeout: 600)
    }

    public func importMedia(
        sha256: String, name: String, dataB64: String
    ) async throws -> CompanionMediaImportOutcome {
        try await post(
            "import/media",
            body: MediaImportRequest(sha256: sha256, name: name, dataB64: dataB64),
            timeout: 300)
    }

    public func deleteEpisode(id: String) async throws -> CompanionEpisodeDeletion {
        var request = URLRequest(url: url(for: "episodes/\(id)"))
        request.httpMethod = "DELETE"
        return try await self.request(request)
    }

    public func wipe(confirm: String) async throws -> CompanionWipeOutcome {
        try await post("db/wipe", body: WipeRequest(confirm: confirm), timeout: 300)
    }
}

private struct MediaImportRequest: Encodable {
    let sha256: String
    let name: String
    let dataB64: String
}

private struct WipeRequest: Encodable {
    let confirm: String
}
