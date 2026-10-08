import Foundation

@objc(EdithAudioMixerExtensionRuntime)
final class AudioMixerExtensionRuntime: NSObject {
    @objc func execute(_ input: NSDictionary) -> NSDictionary {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: Self.self)
            return [
                "id": "audioMixer", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ]
        case "start", "stop", "synchronize": return ["ok": true]
        default: return ["ok": false]
        }
    }
}

@_cdecl("edith_extension_create")
public func edithAudioMixerExtensionCreate() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(AudioMixerExtensionRuntime()).toOpaque()
}
