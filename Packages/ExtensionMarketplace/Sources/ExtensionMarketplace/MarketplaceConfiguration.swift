import Foundation

public enum MarketplaceConfiguration {
    public static let workerHostABI = "edith-host-2"
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "host-35b1a5055392c885077ed1b7"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogTag = "extension-catalog-v1"
    public static let catalogURL = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/releases/tags/extension-catalog-v1")!
}
