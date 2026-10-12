import CryptoKit
import Foundation

struct ExtensionCatalogPointer: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let revision: Int64
    let assetName: String
    let sha256: String
    let bytes: Int

    static func parse(_ body: String) throws -> Self {
        guard let data = body.data(using: .utf8), data.count <= 1024,
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == ["schemaVersion", "revision", "assetName", "sha256", "bytes"]
        else { throw MarketplaceError.invalidCatalog }
        let expression = try NSRegularExpression(
            pattern: "\"(assetName|bytes|revision|schemaVersion|sha256)\"\\s*:")
        let keys = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .compactMap { Range($0.range(at: 1), in: body).map { String(body[$0]) } }
        guard keys.count == 5, Set(keys).count == 5 else { throw MarketplaceError.invalidCatalog }
        let pointer = try JSONDecoder().decode(Self.self, from: data)
        guard pointer.schemaVersion == 1, pointer.revision > 0,
            pointer.revision <= 9_007_199_254_740_991,
            pointer.assetName == "catalog-\(pointer.revision).json",
            pointer.bytes > 0, pointer.bytes <= 3 * 1024 * 1024,
            pointer.sha256.count == 64,
            pointer.sha256.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase })
        else { throw MarketplaceError.invalidCatalog }
        return pointer
    }

    func verify(_ data: Data) throws {
        guard data.count == bytes,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha256
        else { throw MarketplaceError.invalidCatalog }
    }
}
