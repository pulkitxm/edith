import AttentionNative
import Foundation

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let controller = MainActor.assumeIsolated {
        AttentionExtensionController(bundle: Bundle(for: AttentionRuntimeBundle.self))
    }
    return Unmanaged.passRetained(controller).toOpaque()
}

private final class AttentionRuntimeBundle: NSObject {}
