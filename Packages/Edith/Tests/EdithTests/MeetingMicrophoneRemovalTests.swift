import EdithLidAwakeSupport
import Foundation
import Testing

struct MeetingMicrophoneRemovalTests {
    @Test func removesAnInstalledDriverOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let driver = root.appendingPathComponent("com.pulkit.edith.microphone.driver")
        let binary = driver.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: true)
        try Data("driver".utf8).write(to: binary.appendingPathComponent("EdithMicrophone"))
        #expect(try MeetingMicrophoneRemoval.remove(at: driver))
        #expect(!FileManager.default.fileExists(atPath: driver.path))
        #expect(try !MeetingMicrophoneRemoval.remove(at: driver))
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func targetsTheProductionDriverPath() {
        #expect(
            MeetingMicrophoneRemoval.installed.path
                == "/Library/Audio/Plug-Ins/HAL/com.pulkit.edith.microphone.driver")
    }
}
