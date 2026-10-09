import Foundation

@_cdecl("edith_extension_create")
public func createCameraCarrier() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(CameraCarrierRuntime()).toOpaque())
        })
}
