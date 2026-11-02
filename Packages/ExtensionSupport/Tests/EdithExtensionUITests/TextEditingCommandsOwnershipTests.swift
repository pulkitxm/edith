import EdithExtensionUI
import Foundation
import Testing

@MainActor @Suite(.serialized) struct TextEditingCommandsOwnershipTests {
    @Test func theMonitorStaysUntilEveryOwnerShutsDown() throws {
        let first = try #require(UnsafeRawPointer(bitPattern: 0x7200_1000))
        let second = try #require(UnsafeRawPointer(bitPattern: 0x7200_2000))
        TextEditingCommands.install(image: first)
        TextEditingCommands.install(image: second)
        TextEditingCommands.shutdown(image: first)
        #expect(TextEditingCommands.isInstalled)
        TextEditingCommands.shutdown(image: second)
        #expect(!TextEditingCommands.isInstalled)
    }
}
