import AttentionNative
import Foundation

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let controller = MainActor.assumeIsolated {
        makeAttentionRuntime(bundle: Bundle(for: AttentionRuntimeBundle.self))
    }
    return Unmanaged.passRetained(controller).toOpaque()
}

private final class AttentionRuntimeBundle: NSObject {}
