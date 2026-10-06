import EdithCore
import Foundation

public enum MeetingMicrophone {
    public static var id: String { AppBuildIdentity.application + ".microphone" }
    public static var name: String {
        AppBuildIdentity.developmentSlot.map { "Edith Microphone (\($0))" } ?? "Edith Microphone"
    }
    public static var installed: Bool { MeetingAudioDevices.list().contains { $0.id == id } }
}
