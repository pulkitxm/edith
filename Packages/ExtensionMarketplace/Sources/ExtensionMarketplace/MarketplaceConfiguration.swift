import Foundation

public enum MarketplaceConfiguration {
    public static let workerHostABI = "edith-host-3"
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "host-02c4895459560f83e1faf981"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogTag = "extension-catalog-v1"
    public static let catalogURL = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/releases/tags/extension-catalog-v1")!
}
