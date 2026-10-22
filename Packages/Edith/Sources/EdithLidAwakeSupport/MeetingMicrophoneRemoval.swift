import Foundation

public enum MeetingMicrophoneRemoval {
    public static let installed = URL(
        fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/com.pulkit.edith.microphone.driver")

    @discardableResult
    public static func remove(at driver: URL = installed) throws -> Bool {
        do {
            try FileManager.default.removeItem(at: driver)
            return true
        } catch CocoaError.fileNoSuchFile {
            return false
        }
    }
}
