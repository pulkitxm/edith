import AVFoundation
import AppKit
import CoreImage
import EdithCameraSupport
import Foundation
import SwiftUI
import SystemExtensions
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
@Suite(.serialized) struct VirtualCameraPageModelTests {
    static let sources = [
        VirtualCameraSource(id: "cam-a", name: "FaceTime HD Camera", kind: .builtIn),
        VirtualCameraSource(id: "cam-b", name: "Desk View Camera", kind: .deskView),
    ]

    static func model() -> (VirtualCameraPageModel, UserDefaults, String) {
        let name = "test.edith.virtual-camera-page.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let model = VirtualCameraPageModel(
            defaults: defaults,
            pipeline: VirtualCameraPipeline(
                state: VirtualCameraState(), outputSize: CGSize(width: 320, height: 180)),
            extensionManager: VirtualCameraExtensionManager(
                environment: VirtualCameraExtensionEnvironment(
                    bundleURL: URL(fileURLWithPath: "/tmp/Missing.app"),
                    hasInstallEntitlement: { false }, deviceVisible: { false })),
            accessProvider: { .denied }, sourceProvider: { sources })
        return (model, defaults, name)
    }

    @Test func editsPersistAfterTheDebouncedSave() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        model.updateComposition { $0.look.preset = .film }
        #expect(model.composition.framing.zoom == 2)
        #expect(VirtualCameraStore.load(defaults).composition.look.preset == .natural)
        model.flushSave()
        let stored = VirtualCameraStore.load(defaults)
        #expect(stored.composition.framing.zoom == 2)
        #expect(stored.composition.look.preset == .film)
    }

    @Test func dragAndZoomFollowTheGeometry() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(2)
        let before = model.composition.framing.centerX
        model.pan(by: CGSize(width: 100, height: 0), in: CGSize(width: 960, height: 540))
        #expect(model.composition.framing.centerX < before)
        model.zoom(by: 2, anchor: CGPoint(x: 0.5, y: 0.5))
        #expect(model.composition.framing.zoom == 4)
        model.updateComposition { $0.framing.autoFrame = .close }
        model.resetFraming()
        #expect(model.composition.framing == VirtualCameraFraming(autoFrame: .close))
    }

    @Test func rotationWrapsAround() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.rotate(clockwise: false)
        #expect(model.composition.framing.quarterTurns == 3)
        model.rotate(clockwise: true)
        model.rotate(clockwise: true)
        #expect(model.composition.framing.quarterTurns == 1)
        #expect(model.sourceSize == CGSize(width: 1080, height: 1920))
    }

    @Test func scenesCanBeSavedRenamedAndRemoved() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.setZoom(3)
        model.saveScene(named: "Whiteboard")
        let scene = try #require(model.state.scenes.last)
        #expect(scene.name == "Whiteboard")
        #expect(model.state.activeSceneID == scene.id)
        model.saveScene(named: "whiteboard")
        #expect(model.errorMessage == "A scene named whiteboard already exists.")
        model.errorMessage = nil
        model.renameScene(scene, to: "Board")
        #expect(model.state.scenes.last?.name == "Board")
        model.duplicateScene(try #require(model.state.scenes.last))
        #expect(model.state.scenes.map(\.name).suffix(2) == ["Board", "Board 2"])
        model.apply(model.state.scenes[1])
        #expect(model.composition.framing.zoom == 1.6)
        model.setZoom(1.8)
        #expect(model.state.activeSceneIsModified)
        model.updateScene(model.state.scenes[1])
        #expect(!model.state.activeSceneIsModified)
        model.moveScene(model.state.scenes[0], by: 1)
        #expect(model.state.scenes[1].name == "Full frame")
        model.deleteScene(try #require(model.state.scenes.last))
        #expect(model.state.scenes.count == 3)
        #expect(model.suggestedSceneName() == "Scene")
    }

    @Test func pausingAndCamerasUpdateTheState() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.refreshSources()
        #expect(model.selectedSource?.id == "cam-a")
        model.selectSource(Self.sources[1])
        #expect(model.selectedSource?.name == "Desk View Camera")
        model.pause(.freeze)
        #expect(model.state.privacy == .freeze)
        model.resume()
        #expect(model.state.privacy == .live)
    }

    @Test func removingAnImageTurnsItsFeatureOff() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.updateComposition {
            $0.background = VirtualCameraBackground(mode: .image, imagePath: "/tmp/b.png")
            $0.overlays.logo = VirtualCameraLogo(enabled: true, imagePath: "/tmp/l.png")
        }
        model.removeImage(for: .background)
        model.removeImage(for: .logo)
        #expect(model.composition.background.mode == .none)
        #expect(model.composition.background.imagePath == nil)
        #expect(!model.composition.overlays.logo.enabled)
        #expect(VirtualCameraStore.load(defaults).composition.background.mode == .none)
    }

    @Test func importingRejectsFilesThatAreNotImages() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        model.importImage(file, for: .logo)
        #expect(model.errorMessage?.contains("not an image") == true)
        #expect(model.composition.overlays.logo.imagePath == nil)
    }

    @Test func statusCombinesTheHelperAndTheState() {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        model.injectForTesting(snapshot: nil, sources: [])
        #expect(model.statusHeadline == "Edith Bar is not answering")
        var snapshot = VirtualCameraSnapshot(
            enabled: true, helperRunning: true, extensionInstalled: true,
            clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
            format: .hd720, state: model.state)
        model.receive(snapshot)
        #expect(model.isLive)
        #expect(model.statusHeadline == "Live in zoom.us")
        #expect(model.outputSize == CGSize(width: 1280, height: 720))
        snapshot.live = false
        model.receive(snapshot)
        #expect(!model.isLive)
        model.receive(nil)
        #expect(model.snapshot == snapshot)
    }

    @Test func previewFramesReachTheDisplay() throws {
        let (model, defaults, name) = Self.model()
        defer { defaults.removePersistentDomain(forName: name) }
        let input = try #require(VirtualCameraFixtures.quadrants())
        model.renderPreview(from: input)
        let shown = try #require(model.display.current)
        #expect(CVPixelBufferGetWidth(shown) == 320)
        model.display.clear()
        #expect(model.display.current == nil)
    }
}

@MainActor
@Suite struct VirtualCameraExtensionManagerTests {
    @Test func phasesExplainWhatBlocksTheInstall() {
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: false, inApplications: false,
                deviceVisible: true) == .installed)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: false, entitled: true, inApplications: true,
                deviceVisible: false) == .missingFromBundle)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: false, inApplications: true,
                deviceVisible: false) == .needsSigning)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: true, inApplications: false,
                deviceVisible: false) == .needsApplicationsFolder)
        #expect(
            VirtualCameraExtensionManager.phase(
                bundleContainsExtension: true, entitled: true, inApplications: true,
                deviceVisible: false) == .notInstalled)
        #expect(VirtualCameraExtensionPhase.notInstalled.canInstall)
        #expect(VirtualCameraExtensionPhase.failed("x").canInstall)
        #expect(!VirtualCameraExtensionPhase.needsSigning.canInstall)
        #expect(!VirtualCameraExtensionPhase.installed.canInstall)
    }

    @Test func refreshReadsTheBundleEntitlementAndDevice() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("camera-bundle-\(UUID().uuidString)")
        let app = root.appendingPathComponent("Edith.app")
        let extensionURL = app.appendingPathComponent(
            "Contents/Library/SystemExtensions/\(VirtualCameraExtensionManager.identifier).systemextension"
        )
        try FileManager.default.createDirectory(at: extensionURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var visible = false
        var entitled = false
        let manager = VirtualCameraExtensionManager(
            environment: VirtualCameraExtensionEnvironment(
                bundleURL: app, hasInstallEntitlement: { entitled }, deviceVisible: { visible }))
        #expect(manager.extensionBundleURL.standardizedFileURL == extensionURL.standardizedFileURL)
        #expect(!manager.inApplicationsFolder)
        manager.refresh()
        #expect(manager.phase == .needsSigning)
        entitled = true
        manager.refresh()
        #expect(manager.phase == .needsApplicationsFolder)
        visible = true
        manager.refresh()
        #expect(manager.phase == .installed)
        manager.install()
        #expect(manager.phase == .installed)
    }

    @Test func systemExtensionErrorsBecomeGuidance() {
        func message(_ code: OSSystemExtensionError.Code) -> String {
            VirtualCameraExtensionManager.message(
                for: NSError(domain: OSSystemExtensionErrorDomain, code: code.rawValue))
        }
        #expect(message(.missingEntitlement) == VirtualCameraExtensionPhase.needsSigning.detail)
        #expect(
            message(.unsupportedParentBundleLocation)
                == VirtualCameraExtensionPhase.needsApplicationsFolder.detail)
        #expect(message(.extensionNotFound) == VirtualCameraExtensionPhase.missingFromBundle.detail)
        #expect(message(.codeSignatureInvalid).contains("signature"))
        #expect(message(.requestCanceled) == "The request was canceled.")
        let other = NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        #expect(VirtualCameraExtensionManager.message(for: other) == "boom")
        #expect(!VirtualCameraExtensionManager.selfHasEntitlement())
    }
}

@MainActor
@Suite struct VirtualCameraPreviewViewTests {
    @Test func anchorsAreNormalizedFromTheTopLeft() {
        let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 10, y: 120), in: rect, mirrored: false)
                == CGPoint(x: 0, y: 0))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 210, y: 20), in: rect, mirrored: false)
                == CGPoint(x: 1, y: 1))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: CGPoint(x: 60, y: 70), in: rect, mirrored: true)
                == CGPoint(x: 0.75, y: 0.5))
        #expect(
            VirtualCameraPreviewNSView.anchor(
                of: CGPoint(x: -50, y: 900), in: rect, mirrored: false)
                == CGPoint(x: 0, y: 0))
        #expect(
            VirtualCameraPreviewNSView.anchor(of: .zero, in: .zero, mirrored: false)
                == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func scrollingUpZoomsIn() {
        #expect(VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 10, precise: true) > 1)
        #expect(VirtualCameraPreviewNSView.zoomFactor(scrollDelta: -10, precise: true) < 1)
        #expect(
            VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 1, precise: false)
                > VirtualCameraPreviewNSView.zoomFactor(scrollDelta: 1, precise: true))
    }

    @Test func thePictureKeepsItsAspectInsideTheView() {
        let view = VirtualCameraPreviewNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        #expect(view.pictureRect == CGRect(x: 0, y: 87.5, width: 400, height: 225))
        view.frame = CGRect(x: 0, y: 0, width: 1000, height: 225)
        #expect(view.pictureRect == CGRect(x: 300, y: 0, width: 400, height: 225))
    }

    @Test func draggingReportsPointerDeltas() throws {
        let view = VirtualCameraPreviewNSView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        var deltas: [CGSize] = []
        var resets = 0
        view.onPan = { delta, size in
            deltas.append(delta)
            #expect(size == CGSize(width: 320, height: 180))
        }
        view.onReset = { resets += 1 }
        func event(_ type: NSEvent.EventType, _ point: CGPoint, clicks: Int = 1) throws -> NSEvent {
            try #require(
                NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks,
                    pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 100, y: 100)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 130, y: 90)))
        #expect(deltas == [CGSize(width: 30, height: 10)])
        view.mirrored = true
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 140, y: 90)))
        #expect(deltas.last == CGSize(width: -10, height: 0))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 140, y: 90)))
        view.mouseDragged(with: try event(.leftMouseDragged, CGPoint(x: 200, y: 90)))
        #expect(deltas.count == 2)
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 50, y: 50), clicks: 2))
        #expect(resets == 1)
    }
}

enum VirtualCameraSyntheticStudio {
    static let size = CGSize(width: 1920, height: 1080)

    static func context() -> CGContext? {
        CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1)
        -> CGColor
    {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    static func person(in context: CGContext, fill: CGColor?) {
        let skin = fill ?? color(0.86, 0.68, 0.56)
        let sweater = fill ?? color(0.16, 0.25, 0.42)
        let hair = fill ?? color(0.2, 0.13, 0.09)
        context.setFillColor(sweater)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 610, y: -120, width: 700, height: 420), cornerWidth: 190,
                cornerHeight: 190, transform: nil))
        context.fillPath()
        context.setFillColor(skin)
        context.fill(CGRect(x: 910, y: 250, width: 100, height: 110))
        context.fillEllipse(in: CGRect(x: 820, y: 330, width: 280, height: 350))
        context.setFillColor(hair)
        context.addPath(
            CGPath(
                roundedRect: CGRect(x: 805, y: 560, width: 310, height: 150), cornerWidth: 120,
                cornerHeight: 70, transform: nil))
        context.fillPath()
        guard fill == nil else { return }
        context.setFillColor(color(0.18, 0.12, 0.1))
        context.fillEllipse(in: CGRect(x: 895, y: 500, width: 28, height: 20))
        context.fillEllipse(in: CGRect(x: 997, y: 500, width: 28, height: 20))
        context.setStrokeColor(color(0.55, 0.3, 0.3))
        context.setLineWidth(8)
        context.addArc(
            center: CGPoint(x: 960, y: 450), radius: 45, startAngle: .pi * 1.15,
            endAngle: .pi * 1.85, clockwise: false)
        context.strokePath()
    }

    static func frame() -> CGImage? {
        guard let context = context() else { return nil }
        let wall = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0.93, 0.87, 0.78), color(0.72, 0.64, 0.55)] as CFArray,
            locations: [0, 1])!
        context.drawLinearGradient(
            wall, start: CGPoint(x: 0, y: 1080), end: CGPoint(x: 1920, y: 0), options: [])
        context.setFillColor(color(0.45, 0.3, 0.2))
        context.fill(CGRect(x: 1320, y: 180, width: 460, height: 760))
        let books: [CGColor] = [
            color(0.75, 0.2, 0.2), color(0.2, 0.45, 0.6), color(0.9, 0.7, 0.2),
            color(0.3, 0.55, 0.35), color(0.55, 0.35, 0.6),
        ]
        for shelf in 0..<3 {
            let y = 220 + CGFloat(shelf) * 240
            context.setFillColor(color(0.32, 0.2, 0.13))
            context.fill(CGRect(x: 1330, y: y - 12, width: 440, height: 12))
            for index in 0..<9 {
                context.setFillColor(books[(index + shelf) % books.count])
                context.fill(
                    CGRect(
                        x: 1345 + CGFloat(index) * 46, y: y,
                        width: 38, height: 150 + CGFloat((index * 37 + shelf * 11) % 50)))
            }
        }
        context.setFillColor(color(0.78, 0.88, 0.96))
        context.fill(CGRect(x: 160, y: 420, width: 420, height: 480))
        context.setStrokeColor(color(1, 1, 1))
        context.setLineWidth(18)
        context.stroke(CGRect(x: 160, y: 420, width: 420, height: 480))
        context.setFillColor(color(0.95, 0.85, 0.5, 0.9))
        context.fillEllipse(in: CGRect(x: 250, y: 240, width: 160, height: 120))
        person(in: context, fill: nil)
        return context.makeImage()
    }

    static func mask() -> CIImage? {
        guard let context = context() else { return nil }
        context.setFillColor(color(0, 0, 0))
        context.fill(CGRect(origin: .zero, size: size))
        person(in: context, fill: color(1, 1, 1))
        return context.makeImage().map { CIImage(cgImage: $0) }
    }

    static func buffer() -> CVPixelBuffer? {
        guard let image = frame(),
            let buffer = VirtualCameraPlaceholder.makeBuffer(
                width: Int(size.width), height: Int(size.height))
        else { return nil }
        VirtualCameraFixtures.context.render(
            CIImage(cgImage: image), to: buffer, bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return buffer
    }
}

@MainActor
@Suite(.serialized) struct VirtualCameraEvidenceTests {
    static let directory = ProcessInfo.processInfo.environment["EDITH_VIRTUAL_CAMERA_EVIDENCE_DIR"]

    @Test func syntheticStudioAndMaskAreDistinct() throws {
        let frame = try #require(VirtualCameraSyntheticStudio.frame())
        #expect(frame.width == 1920)
        let mask = try #require(VirtualCameraSyntheticStudio.mask())
        #expect(mask.extent.size == VirtualCameraSyntheticStudio.size)
    }

    @Test(.enabled(if: directory != nil))
    func renderEvidence() throws {
        let output = URL(fileURLWithPath: try #require(Self.directory), isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let renderer = VirtualCameraRenderer()
        let studio = CIImage(cgImage: try #require(VirtualCameraSyntheticStudio.frame()))
        let mask = VirtualCameraSyntheticStudio.mask()
        let size = CGSize(width: 1280, height: 720)
        let logo = renderer.context.createCGImage(
            CIImage(color: CIColor(red: 0.04, green: 0.52, blue: 1)).cropped(
                to: CGRect(x: 0, y: 0, width: 240, height: 90)),
            from: CGRect(x: 0, y: 0, width: 240, height: 90))

        func write(_ image: CIImage, _ name: String) throws {
            let cgImage = try #require(renderer.cgImage(image, size: size))
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(name))
        }

        var closeUp = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.7, centerX: 0.5, centerY: 0.44),
            look: VirtualCameraLook(preset: .studio, warmth: 0.1, vignette: 0.25),
            background: VirtualCameraBackground(mode: .blur, blur: 0.8),
            overlays: VirtualCameraOverlays(
                nameTag: VirtualCameraNameTag(
                    enabled: true, title: "Ada Lovelace", subtitle: "Staff Engineer",
                    style: .bar, corner: .bottomLeft)))
        try write(
            renderer.compose(
                VirtualCameraFrameInput(image: studio, composition: VirtualCameraComposition()),
                output: size), "output-raw.png")
        try write(
            renderer.compose(
                VirtualCameraFrameInput(image: studio, composition: closeUp, mask: mask),
                output: size), "output-close-up.png")
        closeUp.background = VirtualCameraBackground(
            mode: .color, color: VirtualCameraColor(hex: "#1E293B") ?? .black)
        closeUp.look = VirtualCameraLook(preset: .noir)
        closeUp.overlays.nameTag.style = .pill
        closeUp.overlays.border = VirtualCameraBorder(
            enabled: true, width: 0.006, cornerRadius: 0.06, inset: 0.05)
        closeUp.overlays.clock = VirtualCameraClock(
            enabled: true, corner: .topRight, twentyFourHour: true)
        try write(
            renderer.compose(
                VirtualCameraFrameInput(
                    image: studio, composition: closeUp, mask: mask,
                    date: Date(timeIntervalSince1970: 1_790_000_000)),
                output: size), "output-studio-frame.png")
        var branded = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.25, centerX: 0.55, centerY: 0.48, tilt: -2),
            look: VirtualCameraLook(preset: .warm))
        branded.overlays.logo = VirtualCameraLogo(
            enabled: true, imagePath: "/synthetic/logo.png", corner: .topLeft, size: 0.08)
        try write(
            renderer.compose(
                VirtualCameraFrameInput(
                    image: studio, composition: branded,
                    assets: VirtualCameraAssets(logo: logo.map { CIImage(cgImage: $0) })),
                output: size), "output-branded.png")
        let backdrop = renderer.compose(
            VirtualCameraFrameInput(image: studio, composition: VirtualCameraComposition()),
            output: size)
        try write(
            renderer.privacyImage(
                .card, message: "Back in 5 minutes", backdrop: backdrop, output: size),
            "output-pause-card.png")
        let offline = try #require(VirtualCameraPlaceholder.makeBuffer(width: 1280, height: 720))
        VirtualCameraPlaceholder.render(VirtualCameraPlaceholder.card(for: .offline), into: offline)
        try write(CIImage(cvPixelBuffer: offline), "extension-offline.png")

        let (model, defaults, name) = VirtualCameraPageModelTests.model()
        defer { defaults.removePersistentDomain(forName: name) }
        var state = model.state
        state.composition = VirtualCameraComposition(
            framing: VirtualCameraFraming(zoom: 1.7, centerX: 0.5, centerY: 0.44),
            look: VirtualCameraLook(preset: .studio, warmth: 0.1, vignette: 0.25),
            background: VirtualCameraBackground(mode: .blur, blur: 0.8),
            overlays: VirtualCameraOverlays(
                nameTag: VirtualCameraNameTag(
                    enabled: true, title: "Ada Lovelace", subtitle: "Staff Engineer")))
        _ = try? VirtualCameraSceneLibrary.save("Interview", in: &state)
        model.update { $0 = state }
        model.injectForTesting(
            snapshot: VirtualCameraSnapshot(
                enabled: true, helperRunning: true, extensionInstalled: true, extensionBuild: "288",
                clients: [VirtualCameraClient(id: "us.zoom.xos", name: "zoom.us")], live: true,
                framesPerSecond: 30, source: VirtualCameraPageModelTests.sources[0],
                sourceWidth: 1920, sourceHeight: 1080, sources: VirtualCameraPageModelTests.sources,
                format: .hd1080, cameraAccess: "granted", state: model.state),
            sources: VirtualCameraPageModelTests.sources)
        let preview = renderer.compose(
            VirtualCameraFrameInput(image: studio, composition: model.composition, mask: mask),
            output: size)
        let buffer = try #require(VirtualCameraPlaceholder.makeBuffer(width: 1280, height: 720))
        renderer.render(preview, into: buffer)
        model.showPreviewFrame(buffer)
        for tab in [VirtualCameraInspectorTab.frame, .look, .overlays, .output] {
            model.tab = tab
            try renderPage(
                model, preview: preview, renderer: renderer,
                to: output.appendingPathComponent("page-\(tab.rawValue).png"))
        }
    }

    private func renderPage(
        _ model: VirtualCameraPageModel, preview: CIImage, renderer: VirtualCameraRenderer,
        to url: URL
    ) throws {
        let host = NSHostingView(
            rootView: VirtualCameraPage(model: model)
                .environment(\.colorScheme, .dark)
                .transaction { $0.animation = nil })
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 1060)
        host.appearance = NSAppearance(named: .darkAqua)
        let window = TestWindowHost.window(contentRect: host.frame)
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        window.orderBack(nil)
        for _ in 0..<3 {
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
        let previewView = try #require(Self.find(VirtualCameraPreviewNSView.self, in: host))
        let container = try #require(previewView.superview)
        let image = try #require(renderer.cgImage(preview, size: CGSize(width: 1280, height: 720)))
        let frame = previewView.convert(previewView.pictureRect, to: container)
        let overlay = NSImageView(frame: frame)
        overlay.image = NSImage(cgImage: image, size: frame.size)
        overlay.imageScaling = .scaleAxesIndependently
        overlay.wantsLayer = true
        overlay.layer?.cornerRadius = 14
        overlay.layer?.masksToBounds = true
        container.addSubview(overlay, positioned: .above, relativeTo: previewView)
        defer { overlay.removeFromSuperview() }
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview) { return match }
        }
        return nil
    }
}
