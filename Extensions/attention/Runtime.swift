import AttentionNative
import Foundation

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated {
        Unmanaged.passRetained(
            AttentionExtensionController(bundle: Bundle(for: AttentionRuntimeBundle.self))
        ).toOpaque()
    }
}

private final class AttentionRuntimeBundle: NSObject {}
