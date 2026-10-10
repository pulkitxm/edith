import Foundation

public enum MarketplaceConfiguration {
    public static let workerHostABI = "edith-host-2"
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "host-4f3884ecc4231cd80dbd0e18"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogURL = URL(
        string:
            "https://github.com/pulkitxm/edith/releases/download/extension-catalog-v1/catalog.json")!
}
