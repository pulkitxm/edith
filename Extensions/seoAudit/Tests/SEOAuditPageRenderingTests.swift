import AppKit
import EdithExtensionUI
import SwiftUI
import Testing
@testable import SEOAuditExtension

@MainActor @Suite(.serialized) struct SEOAuditPageRenderingTests {
    @Test func fullProjectAndHistoryPageRendersCompactWideZoomedAndDark() async throws {
        _ = NSApplication.shared
        let attributes = ["AXManualAccessibility", "AXEnhancedUserInterface"].map {
            NSAccessibility.Attribute(rawValue: $0)
        }
        let prior = attributes.map { NSApp.accessibilityAttributeValue($0) }
        for attribute in attributes { NSApp.accessibilitySetValue(true, forAttribute: attribute) }
        defer {
            for (attribute, value) in zip(attributes, prior) {
                NSApp.accessibilitySetValue(value ?? false, forAttribute: attribute)
            }
        }
        let previous = UIScale.current
        defer { UIScale.apply(previous) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let page = SEOAuditPageResult(
            url: "https://synthetic.example.invalid/docs", statusCode: 200,
            responseMilliseconds: 20, bytes: 100, metadata: .empty,
            issues: [
                .init(
                    code: "title", severity: .error, title: "Missing title",
                    detail: "Add a descriptive title.")
            ])
        let project = SEOAuditProject(
            name: "Synthetic site", baseURL: "https://synthetic.example.invalid",
            runs: [.init(state: .completed, discoveredPageCount: 1, pages: [page])])
        try SEOAuditRepository(root: root).save(project)
        let service = SEOAuditService(
            workflow: SEOAuditWorkflow(
                repository: SEOAuditRepository(root: root),
                lighthouse: LighthouseAuditor(locate: { nil })))
        let model = SEOAuditModel(service: service)
        await model.refreshProjects()
        for (width, zoom) in [(360.0, 1.6), (900.0, 1.0)] {
            UIScale.apply(zoom)
            for scheme in [ColorScheme.light, .dark] {
                for detail in [false, true] {
                    if detail {
                        await model.selectProject(id: project.id)
                    } else {
                        model.closeProject()
                    }
                    let view = SEOAuditPage(model: model).frame(width: width, height: 800)
                        .environment(\.compactLayout, width < 600).environment(
                            \.colorScheme, scheme
                        )
                        .environment(\.automaticViewActionsEnabled, false)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 800)
                    let window = NSWindow(
                        contentRect: host.frame, styleMask: [.borderless], backing: .buffered,
                        defer: false)
                    window.isReleasedWhenClosed = false;
                    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                    window.contentView = host; window.orderBack(nil)
                    try await Task.sleep(for: .milliseconds(75)); host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    let labels = accessibleLabels(host)
                    #expect(labels.contains { $0.contains("Synthetic site") })
                    #expect(labels.contains { $0.contains(detail ? "Audit" : "New project") })
                    window.orderOut(nil); window.close()
                }
            }
        }
        #expect(service.jobCount == 0)
        model.shutdown(); await service.shutdown()
    }
    private func accessibleLabels(_ node: AnyObject, depth: Int = 0) -> [String] {
        guard depth < 64 else { return [] }
        var result = [(node as AnyObject).accessibilityLabel?()].compactMap { $0 }
        let selector = NSSelectorFromString("accessibilityValue")
        if let object = node as? NSObject, object.responds(to: selector),
            let text = object.perform(selector)?.takeUnretainedValue() as? String
        {
            result.append(text)
        }
        for child in (node as AnyObject).accessibilityChildren?() as? [AnyObject] ?? [] {
            result += accessibleLabels(child, depth: depth + 1)
        }
        return result
    }
}
