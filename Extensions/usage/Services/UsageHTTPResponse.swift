import Foundation

public enum UsageHTTPResponse {
    public enum Failure: Error {
        case oversized
    }

    public static func read(
        _ request: URLRequest, session: URLSession, maximumBytes: Int = 1_024 * 1_024
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        guard maximumBytes > 0 else { throw Failure.oversized }
        let owned = URLSession(configuration: session.configuration)
        defer { owned.invalidateAndCancel() }
        let (bytes, response) = try await owned.bytes(for: request)
        if response.expectedContentLength > Int64(maximumBytes) {
            throw Failure.oversized
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < maximumBytes else { throw Failure.oversized }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }
}
