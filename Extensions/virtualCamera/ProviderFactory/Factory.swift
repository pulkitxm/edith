import Foundation

@_cdecl("edith_extension_create")
public func createCameraProvider() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeCameraProviderRuntime()).toOpaque())
        })
}
