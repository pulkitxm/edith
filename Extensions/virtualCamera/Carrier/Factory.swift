import Foundation

@_cdecl("edith_extension_create")
public func createCameraCarrier() -> UnsafeMutableRawPointer? {
    MainActor.assumeIsolated { Unmanaged.passRetained(CameraCarrierRuntime()).toOpaque() }
}
