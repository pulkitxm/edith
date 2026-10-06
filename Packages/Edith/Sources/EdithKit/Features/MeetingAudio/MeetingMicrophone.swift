import AppKit
import EdithCore
import Foundation

public enum MeetingMicrophone {
    public static var id: String { AppBuildIdentity.application + ".microphone" }
    public static var name: String {
        AppBuildIdentity.developmentSlot.map { "Edith Microphone (\($0))" } ?? "Edith Microphone"
    }
    public static var installed: Bool { MeetingAudioDevices.list().contains { $0.id == id } }
    public static var installer: URL? {
        var url = Bundle.main.bundleURL
        while url.path != "/" {
            if url.pathExtension == "app" {
                let package = url.appendingPathComponent("Contents/Resources/EdithMicrophone.pkg")
                if FileManager.default.fileExists(atPath: package.path) { return package }
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    @MainActor
    public static func install() throws {
        guard let installer, NSWorkspace.shared.open(installer) else {
            throw MeetingAudioLibrary.error(
                "The Edith Microphone installer is unavailable in this build.")
        }
    }
}
