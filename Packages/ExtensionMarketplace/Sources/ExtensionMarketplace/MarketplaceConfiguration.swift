import Foundation

public enum MarketplaceConfiguration {
    public static let workerHostABI = "edith-host-4"
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "host-daa5050a7a036cd0645ba990"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogTag = "extension-catalog-v1"
    public static let catalogURL = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/releases/tags/extension-catalog-v1")!
}
