import Foundation

public enum MarketplaceConfiguration {
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "runtime-1"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogURL = URL(
        string:
            "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog.json")!
}
