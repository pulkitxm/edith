import Foundation

enum MachineCredentialIdentity {
    static func service(applicationIdentifier: String?, defaultsSuite: String?) -> String {
        applicationIdentifier == "com.pulkit.edith"
            ? "com.pulkit.edith.machines" : (defaultsSuite ?? "edith.extension.tests") + ".machines"
    }
}
