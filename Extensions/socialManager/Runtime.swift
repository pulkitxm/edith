import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class SocialManagerService: ExtensionService {
    private var started = false
    private var model: SocialManagerModel?
    private var settingsUI = false

    var isRunning: Bool { started }

    func start() -> Bool {
        started = true
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard command == "surface.snapshot" || command == "surface.perform" else {
            throw ExtensionPeerError.unavailable
        }
        return try await SurfaceCommandService.execute(
            providerID: "socialManager", command: command, payload: payload,
            snapshot: { _ in SurfaceSnapshot(providerID: "socialManager") },
            perform: { _ in throw ExtensionPeerError.invalidRequest })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard model == nil, !settingsUI else { return false }
        if configuration.uiOnly {
            settingsUI = true
        } else {
            model = SocialManagerModel()
        }
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        if settingsUI {
            return NSHostingController(rootView: ExtensionPageHost { SocialManagerSettings() })
        }
        guard let model else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { SocialManagerPage(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI()
        return []
    }

    func teardown() async {
        started = false
        releaseUI()
    }

    private func releaseUI() {
        settingsUI = false
        let stopping = model
        model = nil
        stopping?.shutdown()
    }
}

@MainActor
func makeSocialManagerRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "socialManager", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in SocialManagerService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeSocialManagerRuntime()).toOpaque())
        })
}
