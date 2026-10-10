import Foundation

enum MusicCredentialIdentity {
    static func service(applicationIdentifier: String?, isolatedIdentity: String) -> String {
        applicationIdentifier == "com.pulkit.edith"
            ? "com.pulkit.edith.music" : isolatedIdentity + ".extension.music"
    }
}
