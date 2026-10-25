import Foundation

enum TerminalWorker {
    struct BroadcastRequest: Codable {
        let command: String
    }

    struct BroadcastResult: Codable, Equatable {
        let sent: Int
        let unavailable: Int
    }

    static func bounded(_ value: String, bytes: Int) -> String {
        var result = ""
        var count = 0
        for scalar in value.unicodeScalars where scalar.value != 0 {
            let size = String(scalar).utf8.count
            guard count + size <= bytes else { break }
            result.unicodeScalars.append(scalar)
            count += size
        }
        return result
    }
}
