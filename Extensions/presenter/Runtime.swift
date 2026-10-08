import AppKit
import EdithKit
import Foundation

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: PresenterDetector?

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "presenter", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            if service == nil { service = PresenterDetector() }
        case "synchronize": service?.applySettings()
        case "stop":
            service?.shutdown()
            service = nil
        case "pauseUntilShareEnds": service?.pauseUntilShareEnds()
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
