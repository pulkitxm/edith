import Foundation
import Testing

@Suite struct CorePagePolicyTests {
    @Test func homeHeaderUsesOneVisibilityAwareClockSchedule() throws {
        let source = try source("Features/Pages/Views/HomePageView.swift")
        #expect(source.contains("visibility.visible ? 1 : 60"))
        #expect(!source.contains("if visibility.visible {\n                TimelineView"))
    }

    @Test func calendarPermissionRefreshIsEventDriven() throws {
        let source = try source("Features/Pages/Views/CalendarPageView.swift")
        #expect(source.contains("NSApplication.didBecomeActiveNotification"))
        #expect(!source.contains("Timer.publish(every: 2"))
    }

    @Test func extensionsAndSystemUseSemanticSharedControls() throws {
        let extensions = try source("Features/Settings/Views/ExtensionsPane.swift")
        let system = try source("Features/Pages/Views/SystemPageView.swift")

        #expect(extensions.contains(".adaptive(minimum:"))
        #expect(extensions.contains("EdithButtonStyle(.selection"))
        #expect(system.contains("EdithButtonStyle(.destructive)"))
        #expect(system.contains(".accessibilityLabel(\"Dismiss status\")"))
    }

    @Test func aboutUsesTheSharedLeadingReadableLayout() throws {
        let source = try source("Features/Settings/Views/AboutPane.swift")
        #expect(source.contains("PageHeader("))
        #expect(source.contains(".pageContent(compact, width: .readable)"))
        #expect(source.contains("PageSectionHeader("))
        #expect(source.contains("EdithButtonStyle(.secondary, tint: theme)"))
        #expect(!source.contains("multilineTextAlignment(.center)"))
    }

    private func source(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Edith")
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
