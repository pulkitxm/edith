import Foundation

public enum VirtualCameraOutput: String, Codable, CaseIterable, Sendable {
    case automatic
    case edithCamera
    case obs

    public var title: String {
        switch self {
        case .automatic: "Automatic"
        case .edithCamera: "Edith Camera"
        case .obs: "OBS Virtual Camera"
        }
    }
}

public enum VirtualCameraRoute: String, Codable, Sendable {
    case edithCamera
    case obs

    public var cameraName: String {
        switch self {
        case .edithCamera: "Edith Camera"
        case .obs: "OBS Virtual Camera"
        }
    }

    public static func resolve(
        _ output: VirtualCameraOutput, edithInstalled: Bool, obsInstalled: Bool
    ) -> VirtualCameraRoute? {
        switch output {
        case .automatic: edithInstalled ? .edithCamera : (obsInstalled ? .obs : nil)
        case .edithCamera: edithInstalled ? .edithCamera : nil
        case .obs: obsInstalled ? .obs : nil
        }
    }
}

public enum VirtualCameraOBS {
    public static let deviceUID = "7626645E-4425-469E-9D8B-97E0FA59AC75"
    public static let bundleIdentifier = "com.obsproject.obs-studio"
}

public enum VirtualCameraOBSDemand: Equatable, Sendable {
    case start
    case stop
    case keep
    case idle

    public static func next(
        installed: Bool, inUse: Bool, streaming: Bool, obsRunning: Bool, triggerQuit: Bool
    ) -> VirtualCameraOBSDemand {
        if streaming {
            return !installed || obsRunning || triggerQuit ? .stop : .keep
        }
        return installed && inUse && !obsRunning ? .start : .idle
    }
}
