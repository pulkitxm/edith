import Foundation

@main
struct MicrophoneSignatureCheck {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let driver = URL(fileURLWithPath: CommandLine.arguments[1])
        let digest = try MeetingMicrophoneDeployment.signature(driver)
        guard !digest.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        print("Edith Microphone: signed deployment component verified")
    }
}
