import AppKit
import EdithKit
import SwiftUI
import Testing

@testable import Edith

@MainActor
@Suite(.serialized) struct ApplicationNavigationExperienceTests {
    @Test(arguments: [320.0, 680.0])
    func changingSelectedTabsRevealsTheWholeTab(width: Double) async throws {
        let host = NSHostingView(rootView: tabs(selection: 29))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: width, height: 90)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for selected in [29, 0, 19] {
            host.rootView = tabs(selection: selected)
            try await Task.sleep(for: .milliseconds(450))
            host.layoutSubtreeIfNeeded()
            let marker = try #require(descendants(host).first { $0.tag == 1000 + selected })
            let scroll = try #require(marker.enclosingScrollView)
            let rect = marker.convert(marker.bounds, to: scroll.contentView)
            #expect(rect.minX >= scroll.contentView.bounds.minX - 2)
            #expect(rect.maxX <= scroll.contentView.bounds.maxX + 2)
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    @Test(arguments: [false, true], [ColorScheme.light, .dark])
    func skillActionsRemainVisibleAndClickable(compact: Bool, scheme: ColorScheme) async throws {
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let oldAttributes = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, oldAttributes) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        let previous = UIScale.current
        UIScale.apply(compact ? 1.6 : 1)
        defer { UIScale.apply(previous) }
        let probe = CatalogActionProbe()
        let skill = try #require(EdithSkillLibrary.skills.first)
        let host = NSHostingView(
            rootView:
                SkillCatalogRow(
                    skill: skill, agents: [], installed: false, disabled: false,
                    preview: { probe.previews += 1 }, install: { _ in probe.installs += 1 }
                )
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(DashSkin.paper(scheme == .dark))
                .environment(\.compactLayout, compact)
                .environment(\.colorScheme, scheme))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: compact ? 680 : 1280, height: 520)
        let window = TestWindowHost.window(contentRect: host.frame)
        window.contentView = host
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.bounds.height - 520) < 2)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let elements = accessibilityElements(host)
        let viewport = window.convertToScreen(host.convert(host.bounds, to: nil))
        for (label, count) in [
            ("Install", { probe.installs }), ("Preview \(skill.name)", { probe.previews }),
        ] {
            let element = try #require(
                elements.first {
                    ($0 as AnyObject).accessibilityRole?() == .button
                        && ($0 as AnyObject).accessibilityLabel?() == label
                })
            let frame = try #require((element as AnyObject).accessibilityFrame?())
            #expect(frame.width > 0 && frame.height > 0)
            #expect(viewport.insetBy(dx: -1, dy: -1).contains(frame))
            let point = window.convertPoint(fromScreen: CGPoint(x: frame.midX, y: frame.midY))
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(
                    NSEvent.mouseEvent(
                        with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                window.sendEvent(event)
            }
            try await Task.sleep(for: .milliseconds(40))
            #expect(count() == 1)
        }
        if let directory = ProcessInfo.processInfo.environment["EDITH_TEST_EVIDENCE_DIR"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(
                to: output.appendingPathComponent(
                    "skills-\(compact ? "compact" : "regular")-\(scheme == .dark ? "dark" : "light").png"
                ))
        }
        #expect(!TestWindowHost.isExposedOnDesktop(window))
    }

    private func tabs(selection: Int) -> AnyView {
        AnyView(
            PageTabStrip(selection: selection) {
                HStack(spacing: 8) {
                    ForEach(0..<30, id: \.self) { index in
                        TabVisibilityMarker(index: index).frame(width: 150, height: 40).id(index)
                    }
                }
            })
    }

    private func accessibilityElements(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(object)).inserted else { return [] }
            let children = (object as AnyObject).accessibilityChildren?() as? [NSObject] ?? []
            return [object] + children.flatMap(visit)
        }
        return visit(root)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants($0) }
    }
}

@MainActor private final class CatalogActionProbe {
    var previews = 0
    var installs = 0
}

private struct TabVisibilityMarker: NSViewRepresentable {
    let index: Int
    func makeNSView(context: Context) -> NSView {
        let view = TabVisibilityView()
        view.marker = 1000 + index
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class TabVisibilityView: NSView {
    var marker = 0
    override var tag: Int { marker }
}
