import EdithExtensionSupport
import Foundation

public enum MeetingMicrophone {
    public static var id: String { AppBuildIdentity.application + ".microphone" }
    public static var name: String {
        AppBuildIdentity.developmentSlot.map { "Edith Microphone (\($0))" } ?? "Edith Microphone"
    }
    public static var deploymentFailure: String? {
        let value = SharedDefaults.store.string(forKey: "meetingMicrophoneDeploymentError")
        return value?.isEmpty == false ? value : nil
    }
    public static var setupMessage: String {
        if let deploymentFailure { return deploymentFailure }
        if AppBuildIdentity.isDevelopment {
            return "Use the installed Edith application to enable its meeting microphone."
        }
        return
            "Complete Edith’s background helper approval in Settings. If setup is complete, restart macOS to load the audio device."
    }
    public static var installed: Bool { MeetingAudioDevices.list().contains { $0.id == id } }
}
