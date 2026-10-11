import Foundation
import Testing

@testable import EdithHostCore

struct HostStoragePackageScopesTests {
    @Test func roleAndCameraCopiesAreIncludedExactlyOnce() throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? NSTemporaryDirectory())
            .resolvingSymlinksInPath()
            .appendingPathComponent("synthetic-package-scopes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostStoragePackageScopes(
            key: "fixture", directory: root, extensionID: "virtualCamera",
            roles: ["app", "helper", "agent", "cli", "privileged"])
        let paths = [
            "virtualCamera/ExtensionCarrier.app/Contents/MacOS/Edith",
            "virtualCamera/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith",
            "virtualCamera/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/virtualCamera/app.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/MacOS/Edith",
            "virtualCamera/CameraCarrier.app/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/cameraCarrier.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/cameraCarrier.bundle/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/privileged.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/privileged.bundle/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/package.json",
        ]
        for (index, path) in paths.enumerated() {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: (index + 1) * 100).write(to: file)
        }
        let measurement = try HostStorageAccounting.scan(scopes: layout.scopes)
        let executables = layout.executableScopeIDs.reduce(Int64(0)) {
            $0 + (measurement.bytes[$1]?.logical ?? 0)
        }
        let frameworks = layout.frameworkScopeIDs.reduce(Int64(0)) {
            $0 + (measurement.bytes[$1]?.logical ?? 0)
        }
        #expect(executables == 2400)
        #expect(frameworks == 2100)
        #expect(measurement.bytes["fixture"]?.logical == 1000)
        #expect(measurement.total.logical == 5500)
        #expect(measurement.total.complete)
        #expect(Set(layout.scopes.map(\.id)).count == layout.scopes.count)
    }
}
