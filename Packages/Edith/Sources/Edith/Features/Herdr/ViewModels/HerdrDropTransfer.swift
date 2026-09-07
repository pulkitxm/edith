import EdithKit
import Foundation

enum HerdrDropTransfer {
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
