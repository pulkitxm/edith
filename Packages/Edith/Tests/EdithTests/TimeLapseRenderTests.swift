import AppKit
import EdithCore
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@Suite(.serialized) struct TimeLapseRenderTests {
    @Test(arguments: ["windows", "displays"])
    @MainActor
    func loadingAndRecoveryUseSharedPresentationAtCompactZoom(sourceMode: String) async throws {
        guard #available(macOS 15.0, *) else { return }
        _ = TestWindowHost.application
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let previous = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, previous) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        let previousZoom = UIScale.current
        UIScale.apply(1.6)
        defer { UIScale.apply(previousZoom) }
        for scheme in [ColorScheme.light, .dark] {
            for failed in [false, true] {
                let recorder = TimeLapseRecorder()
                recorder.sourceMode = sourceMode
                if failed {
                    recorder.sourceLoad.fail(
                        recorder.sourceLoad.begin(),
                        message: "Sample capture service is unavailable.")
                }
                let views = [
                    AnyView(TimeLapseControls(recorder: recorder, enabled: true)),
                    AnyView(TimeLapseSourcePicker(recorder: recorder, compact: true)),
                ]
                for (index, view) in views.enumerated() {
                    let host = try auditHost(
                        view.environment(\.compactLayout, true).environment(\.colorScheme, scheme)
                            .environment(\.automaticViewActionsEnabled, false)
                            .environment(\.loadingAnimationsEnabled, false),
                        size: CGSize(width: 800, height: 850))
                    host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    let window = TestWindowHost.window(contentRect: host.frame)
                    window.appearance = host.appearance
                    window.contentView = host
                    window.orderBack(nil)
                    defer { window.orderOut(nil) }
                    window.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    #expect(!TestWindowHost.isExposedOnDesktop(window))
                    if failed {
                        let text = try auditText(host)
                        let retry = try #require(Self.retryButton(in: host))
                        #expect((retry as AnyObject).isAccessibilityEnabled?() == true)
                        let frame = (retry as AnyObject).accessibilityFrame?() ?? .zero
                        #expect(frame.width > 0 && frame.height > 0)
                        #expect(window.frame.contains(frame))
                        #expect(text.contains("Sample capture service is unavailable."))
                    }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    #expect(png.count > 10000)
                    if let path = ProcessInfo.processInfo.environment[
                        "EDITH_TIMELAPSE_EVIDENCE_DIR"]
                    {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(
                            at: directory, withIntermediateDirectories: true)
                        try png.write(
                            to: directory.appendingPathComponent(
                                "recorder-\(index == 0 ? "page" : "picker")-\(sourceMode)-\(failed ? "recovery" : "loading")-\(scheme).png"
                            ))
                    }
                }
            }
        }
    }

    @MainActor private static func retryButton(in root: NSObject) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            if (object as AnyObject).accessibilityRole?() == NSAccessibility.Role.button,
                (object as AnyObject).accessibilityLabel?() == "Retry"
            {
                return object
            }
            let children = (object as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
            for child in children {
                if let button = find(child) { return button }
            }
            return nil
        }
        return find(root)
    }

    @Test(
        arguments: [1600.0, 1000.0, 760.0, 560.0, 360.0],
        [
            "ready", "recording", "finished", "waiting", "dark", "short", "standard",
            "standard-dark", "standard-recording",
            "zoom", "zoom-dark",
        ])
    @MainActor
    func rendersSyntheticCaptureControlsAndExportLibrary(width: Double, state: String) async throws
    {
        guard #available(macOS 15.0, *) else { return }
        let previousZoom = UIScale.current
        UIScale.apply(state.hasPrefix("zoom") ? 1.6 : 1)
        defer { UIScale.apply(previousZoom) }
        _ = TestWindowHost.application
        let recorder = TimeLapseRecorder()
        recorder.settings.mode = state.hasPrefix("standard") ? .standard : .timeLapse
        recorder.playbackSeconds = state.hasPrefix("standard") ? 5400 : 36
        recorder.sourceMode = "windows"
        recorder.windows = [
            .init(id: 1, application: "Demo Editor", title: "Sample project"),
            .init(id: 2, application: "Demo Browser", title: "Sample dashboard"),
        ]
        recorder.selectedWindows = [1, 2]
        recorder.settings.systemAudio = true
        recorder.recording =
            state == "standard-recording" || state == "recording" || state == "waiting"
            || state == "dark" || state == "short"
        recorder.startedAt = Date().addingTimeInterval(-5400)
        recorder.frames = state.hasPrefix("standard") ? 162000 : 1080
        recorder.bytes = 24_000_000
        if state == "standard-recording" || state == "recording" || state == "finished"
            || state == "dark" || state == "short"
        {
            recorder.preview = try preview()
        }
        recorder.displays = [.init(id: 1, width: 3840, height: 2160)]
        recorder.microphones = [.init(id: "demo-microphone", name: "Demo microphone")]
        var session = TimeLapseSession(settings: recorder.settings, width: 3840, height: 2160)
        session.segments = [
            .init(
                file: "video-000000.mov", kind: "video", frames: 3600,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), duration: 120)
        ]
        session.endedAt = session.startedAt
        let recording = TimeLapseRecording(
            session: session,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "demo-recording"))
        var libraryFixtures = [recording]
        for index in 1..<3 {
            var settings = recorder.settings
            settings.mode = index == 1 ? .timeLapse : .standard
            var saved = TimeLapseSession(settings: settings, width: 3840, height: 2160)
            saved.segments = [
                .init(
                    file: "video-000000.mov", kind: "video", frames: 900,
                    startedAt: saved.startedAt, duration: Double(index * 15))
            ]
            saved.endedAt = index == 1 ? saved.startedAt : nil
            libraryFixtures.append(
                .init(
                    session: saved,
                    directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                        "demo-recording-\(index)")))
        }
        let height: Double =
            state == "finished" ? 1100 : (state == "short" ? 560 : (width > 1200 ? 1250 : 850))
        let host = NSHostingView(
            rootView: TimeLapseControls(
                recorder: recorder,
                recordings: libraryFixtures, loadsSources: false, enabled: true
            ).environment(\.colorScheme, state.hasSuffix("dark") ? .dark : .light)
                .environment(\.compactLayout, width < 640)
                .frame(width: width, height: height)
                .background(state.hasSuffix("dark") ? Color(white: 0.1) : Color.white))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: state.hasSuffix("dark") ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        #expect(recorder.windows.map(\.id) == [1, 2])
        #expect(!recorder.busy)
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10000)
        if recorder.preview != nil {
            var colored = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.blueComponent > 0.25,
                        color.blueComponent > color.redComponent * 1.5,
                        color.greenComponent > color.redComponent * 1.5,
                        color.greenComponent > color.blueComponent * 0.8
                    {
                        colored += 1
                    }
                }
            }
            #expect(colored > 20)
        }
        if let path = ProcessInfo.processInfo.environment["EDITH_TIMELAPSE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let name = "recorder-\(state)-\(Int(width)).png"
            try png.write(to: directory.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }

    @Test(
        arguments: [700.0, 500.0],
        [
            "windows", "displays", "empty", "unavailable", "windows-dark", "displays-dark",
            "empty-dark", "unavailable-dark",
            "windows-zoom", "windows-zoom-dark", "displays-zoom", "displays-zoom-dark",
        ])
    @MainActor
    func rendersVisualSourcePicker(width: Double, state: String) async throws {
        guard #available(macOS 15.0, *) else { return }
        let dark = state.hasSuffix("-dark")
        let previousZoom = UIScale.current
        UIScale.apply(state.contains("zoom") ? 1.6 : 1)
        defer { UIScale.apply(previousZoom) }
        let mode = state.replacingOccurrences(of: "-dark", with: "")
            .replacingOccurrences(of: "-zoom", with: "")
        _ = TestWindowHost.application
        let recorder = TimeLapseRecorder()
        recorder.sourceMode = mode == "displays" ? "displays" : "windows"
        recorder.windows =
            mode == "empty"
            ? []
            : [
                .init(id: 1, application: "Demo Editor", title: "Sample project"),
                .init(id: 2, application: "Demo Browser", title: "Sample dashboard"),
                .init(id: 3, application: "Demo Notes", title: "Meeting notes"),
                .init(id: 4, application: "Demo Design", title: "Color palette"),
                .init(id: 5, application: "Demo Terminal", title: "Sample build"),
                .init(id: 6, application: "Demo Calendar", title: "Weekly plan"),
            ]
        recorder.displays = [
            .init(id: 1, width: 3840, height: 2160),
            .init(id: 2, width: 2560, height: 1440),
        ]
        recorder.selectedWindows = mode == "empty" ? [] : [1, 2]
        recorder.selectedDisplays = [2]
        let fixtures = try Dictionary(
            uniqueKeysWithValues: recorder.windows.map {
                ($0.id, try sourcePreview(title: $0.title, index: Int($0.id)))
            })
        let host = NSHostingView(
            rootView: TimeLapseSourcePicker(
                recorder: recorder, compact: width < 600,
                thumbnail: { _, id in mode == "unavailable" ? nil : fixtures[id] }
            ).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = CGRect(
            x: 0, y: 0, width: PresentationMetrics.width(width),
            height: PresentationMetrics.height(600))
        let window = TestWindowHost.window(contentRect: host.frame)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = window.appearance
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(350))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(png.count > 10000)
        #expect(recorder.selectedDisplays == [2])
        #expect(recorder.selectedWindows == (mode == "empty" ? [] : [1, 2]))
        if mode == "windows" || mode == "displays" {
            var colored = 0
            var sampled = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 8) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 8) {
                    sampled += 1
                    if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                        color.blueComponent > 0.25,
                        color.blueComponent > color.redComponent * 1.5,
                        color.greenComponent > color.redComponent * 1.5
                    {
                        colored += 1
                    }
                }
            }
            #expect(Double(colored) / Double(sampled) > 0.005)
        }
        if let path = ProcessInfo.processInfo.environment["EDITH_TIMELAPSE_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let name = "picker-\(state)\(width < 600 ? "-narrow" : "").png"
            try png.write(to: directory.appendingPathComponent(name))
        }
        window.orderOut(nil)
    }

    @MainActor private func sourcePreview(title: String, index: Int) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 640, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(calibratedWhite: 0.1, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
        ).draw(at: CGPoint(x: 28, y: 320))
        NSAttributedString(
            string: "Synthetic demonstration data",
            attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white]
        ).draw(at: CGPoint(x: 28, y: 276))
        for row in 0..<5 {
            context.setFillColor((index % 2 == 0 ? NSColor.systemBlue : NSColor.systemTeal).cgColor)
            context.fill(
                CGRect(x: 28, y: 70 + row * 38, width: 240 + ((row + index) % 3) * 80, height: 14))
        }
        return try #require(context.makeImage())
    }

    @MainActor private func preview() throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: 960, height: 540, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 960, height: 540))
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        defer { NSGraphicsContext.restoreGraphicsState() }
        for index in 0..<2 {
            let x = CGFloat(index) * 472 + 16
            context.setFillColor(NSColor(calibratedWhite: 0.16, alpha: 1).cgColor)
            context.fill(CGRect(x: x, y: 28, width: 456, height: 484))
            for (line, text) in [
                index == 0 ? "Sample project" : "Sample dashboard",
                index == 0 ? "Build completed" : "24 tasks completed",
                "Synthetic demonstration data",
            ].enumerated() {
                NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(
                            ofSize: line == 0 ? 24 : 16,
                            weight: line == 0 ? .semibold : .regular),
                        .foregroundColor: NSColor.white,
                    ]
                ).draw(at: CGPoint(x: x + 24, y: 434 - CGFloat(line) * 42))
            }
            for row in 0..<6 {
                context.setFillColor(
                    (index == 0 ? NSColor.systemTeal : NSColor.systemBlue)
                        .withAlphaComponent(0.4 + Double(row) / 12).cgColor)
                context.fill(
                    CGRect(
                        x: x + 24, y: 80 + CGFloat(row) * 34,
                        width: 120 + CGFloat((row + index) % 4) * 64, height: 12))
            }
        }
        return try #require(context.makeImage())
    }

}
