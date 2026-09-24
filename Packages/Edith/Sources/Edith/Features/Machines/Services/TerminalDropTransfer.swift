import EdithKit
import Foundation

enum TerminalDropTransfer {
    static func upload(_ urls: [URL], over connection: SSHConnection) async throws -> [String] {
        let directory = try await connection.temporaryDirectory()
        var paths: [String] = []
        for url in urls {
            let path = remotePath(for: url, directory: directory)
            try await connection.upload(localURL: url, toRemotePath: path)
            paths.append(path)
        }
        return paths
    }

    static func remotePath(
        for url: URL, directory: String,
        identifier: String = UUID().uuidString.lowercased()
    ) -> String {
        let safe = url.lastPathComponent.map { character in
            character.isLetter || character.isNumber || "._-".contains(character)
                ? character : "_"
        }
        let name = safe.isEmpty ? "file" : String(safe.prefix(96))
        return FileListing.join(
            parent: directory, name: "edith-drop-\(identifier)-\(name)")
    }
}
