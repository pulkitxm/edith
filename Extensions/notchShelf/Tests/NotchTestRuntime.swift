import AppKit
import EdithExtensionSupport
import Foundation
import WorkerFixtureSupport

@testable import NotchShelfExtension

@MainActor
enum NotchTestRuntime {
    nonisolated(unsafe) static var suite: String?

    static func make(
        admitOrdinaryContext:
            @escaping @MainActor (NSDictionary) throws -> WorkerFixtureAdmission? =
            NotchShelfService.admitOrdinaryContext,
        contextSource: @escaping @MainActor () -> SurfaceHostContext? = {
            SurfaceHostContext.current
        },
        connectedDisplays: @escaping @MainActor () -> [UInt32: CGSize] = {
            Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    guard
                        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? UInt32
                    else { return nil }
                    return (id, screen.frame.size)
                })
        },
        createController:
            @escaping @MainActor (SurfaceHostContext, [NotchPanelDisplay]) -> NotchShelfController =
            {
                NotchShelfController(context: $0, hostDisplays: $1)
            }
    ) -> ExtensionServiceRuntime {
        suite = nil
        ExtensionScope.register(
            ExtensionScope(
                environment: { ProcessInfo.processInfo.environment },
                value: { key in
                    key == "EDITH_SHARED_DEFAULTS_SUITE"
                        ? (NotchTestRuntime.suite ?? ProcessInfo.processInfo.environment[key])
                        : ProcessInfo.processInfo.environment[key]
                },
                defaults: { .standard },
                dataRoot: { ExtensionScope.temporaryDataRoot() }),
            image: #dsohandle)
        let runtime = ExtensionServiceRuntime(id: "notchShelf", role: "helper", bundle: .main) {
            NotchShelfService(
                runtime: $0, admitOrdinaryContext: admitOrdinaryContext,
                contextSource: contextSource, connectedDisplays: connectedDisplays,
                createController: createController)
        }
        return runtime
    }
}
