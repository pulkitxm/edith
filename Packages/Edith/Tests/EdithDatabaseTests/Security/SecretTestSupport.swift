import EdithDatabase
import Foundation

enum DatabaseSecretTestFixtures {
    static let identifier = UUID(uuidString: "B00C8BC7-487F-4EEB-86D1-9391AA232270")!
    static let password = DatabaseSecretReference(identifier: identifier, purpose: .password)
    static let token = DatabaseSecretReference(identifier: identifier, purpose: .token)
    static let apiKey = DatabaseSecretReference(identifier: identifier, purpose: .apiKeySecret)
    static let confirmationSigningKey = DatabaseSecretReference(
        identifier: UUID(uuidString: "936B9BAA-B795-4D2C-B0BD-5775301C749B")!,
        purpose: .confirmationSigningKey)

    static func data(_ value: String) -> Data {
        Data(value.utf8)
    }
}
