import AppKit
import Darwin
import Foundation
import Testing
@testable import ExtensionMarketplace

@Suite(.serialized) @MainActor struct ExtensionBundlePresentationTests {
    @Test func aScopedSDKOwnsIndependentLivePresentationState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = directory.appendingPathComponent("Probe.swift")
        try """
        import AppKit
        import Foundation
        @MainActor final class ProbeController: NSViewController {
            let state: ExtensionPresentationState
            init(state: ExtensionPresentationState) {
                self.state = state
                super.init(nibName: nil, bundle: nil)
            }
            required init?(coder: NSCoder) { nil }
            @objc func snapshot() -> NSDictionary {
                ["compact": state.compact, "visible": state.visible,
                 "width": state.availableWidth, "intrinsic": state.intrinsic]
            }
        }
        @_cdecl("presentation_probe_view")
        public func presentationProbeView() -> UnsafeMutableRawPointer? {
            let address = MainActor.assumeIsolated { () -> UInt? in
                guard let state = ExtensionPresentationState.current else { return nil }
                return UInt(bitPattern: Unmanaged.passRetained(ProbeController(state: state)).toOpaque())
            }
            return address.flatMap { UnsafeMutableRawPointer(bitPattern: $0) }
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let library = directory.appendingPathComponent("ScopedPresentation.dylib")
        let developer = "/Applications/Xcode.app/Contents/Developer"
        let compile = Process()
        compile.executableURL = URL(
            fileURLWithPath: developer + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc")
        compile.arguments = [
            "-sdk", developer + "/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
            "-emit-library", "-module-name", "ScopedPresentationFixture", "-target",
            "arm64-apple-macos14.0",
            "-plugin-path",
            developer + "/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins",
            root.appendingPathComponent(
                "Packages/ExtensionSupport/Sources/EdithExtensionUI/ExtensionPresentationState.swift"
            ).path,
            source.path, "-o", library.path,
        ]
        try compile.run()
        compile.waitUntilExit()
        #expect(compile.terminationStatus == 0)
        try #require(compile.terminationStatus == 0)
        let image = try #require(dlopen(library.path, RTLD_NOW | RTLD_LOCAL))
        let createSymbol = try #require(dlsym(image, "edith_extension_presentation_create"))
        let viewSymbol = try #require(dlsym(image, "presentation_probe_view"))
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
        let create = unsafeBitCast(createSymbol, to: Factory.self)
        let view = unsafeBitCast(viewSymbol, to: Factory.self)
        func context() throws -> NSObject {
            guard let pointer = create() else { throw MarketplaceError.invalidBundle }
            return Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        }
        let factory: @convention(block) () -> NSViewController? = {
            guard let pointer = view() else { return nil }
            return Unmanaged<NSViewController>.fromOpaque(pointer).takeRetainedValue()
        }
        let firstValue = try ExtensionBundlePresentation.make(
            context: context(),
            input: [
                "compact": true, "visible": true, "width": 320.0,
                "intrinsic": true,
            ], factory: factory)
        let first = try #require(firstValue)
        let secondValue = try ExtensionBundlePresentation.make(
            context: context(),
            input: [
                "compact": false, "visible": false, "width": 900.0,
                "intrinsic": false,
            ], factory: factory)
        let second = try #require(secondValue)
        func snapshot(_ presentation: ExtensionBundlePresentation) throws -> NSDictionary {
            try #require(
                presentation.controller.perform(NSSelectorFromString("snapshot"))?
                    .takeUnretainedValue() as? NSDictionary)
        }
        #expect(try snapshot(first)["compact"] as? Bool == true)
        #expect(try snapshot(second)["visible"] as? Bool == false)
        try first.update(compact: false, visible: false, width: 480, intrinsic: true)
        #expect(try snapshot(first)["width"] as? Double == 480)
        #expect(try snapshot(first)["visible"] as? Bool == false)
        #expect(try snapshot(second)["width"] as? Double == 900)
        #expect(throws: MarketplaceError.invalidBundle) {
            try first.update(compact: true, visible: true, width: .infinity, intrinsic: true)
        }
        #expect(throws: MarketplaceError.invalidBundle) {
            try first.update(compact: true, visible: true, width: 480, intrinsic: false)
        }
        #expect(factory() == nil)
    }
}
