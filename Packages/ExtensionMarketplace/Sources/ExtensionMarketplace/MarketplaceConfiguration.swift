import Foundation

public enum MarketplaceConfiguration {
    public static let workerHostABI = "edith-host-2"
    public static let repository = "pulkitxm/edith"
    public static let hostABI = "host-c8f4c196aaa9d5fd1a9fb595"
    public static let publicKey = Data(
        base64Encoded: "ZmEn7Nvq56SkxwSOm7ey0kyBdFERSQgDywlDCuvxZgk=")!
    public static let catalogTag = "extension-catalog-v1"
    public static let catalogURL = URL(
        string: "https://api.github.com/repos/pulkitxm/edith/releases/tags/extension-catalog-v1")!
}
