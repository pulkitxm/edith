import Foundation

enum HerdrDropTransfer {
    static func remotePath(for url: URL, identifier: String = UUID().uuidString.lowercased())
        -> String
    {
        let safe = url.lastPathComponent.map { character in
            character.isLetter || character.isNumber || "._-".contains(character)
                ? character : "_"
        }
        let name = safe.isEmpty ? "file" : String(safe.prefix(96))
        return "/tmp/edith-drop-\(identifier)-\(name)"
    }
}
