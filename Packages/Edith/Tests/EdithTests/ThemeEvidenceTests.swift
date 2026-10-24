import AppKit
@testable import Edith
@testable import EdithKit
import SwiftUI
import Testing

@Suite @MainActor struct ThemeEvidenceTests {
    @Test func evidenceRendersOffscreen() throws {
        let renderer = ImageRenderer(
            content: ThemeEvidenceView()
                .frame(width: 1200, height: 760)
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))

        #expect(data.count > 100_000)
        if let outputDirectory = ProcessInfo.processInfo.environment["EDITH_THEME_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("theme-system.png"))
        }
    }
}

extension ThemeEvidenceTests {
    @Test func dashboardCardsShareOneSurfaceInEveryTheme() throws {
        let store = ThemeStore.shared
        let original = store.theme
        defer { store.theme = original }
        var rows: [NSImage] = []
        for theme in [AppTheme.accent, .blue, .green] {
            store.theme = theme
            for scheme in [ColorScheme.dark, .light] {
                let renderer = ImageRenderer(
                    content: DashboardCardsEvidence(theme: theme)
                        .environment(\.colorScheme, scheme)
                        .frame(width: 900)
                )
                renderer.scale = 2
                rows.append(try #require(renderer.nsImage))
            }
        }
        let width = rows.map(\.size.width).max() ?? 0
        let height = rows.map(\.size.height).reduce(0, +)
        let sheet = NSImage(size: NSSize(width: width, height: height))
        sheet.lockFocus()
        var y = height
        for row in rows {
            y -= row.size.height
            row.draw(at: NSPoint(x: 0, y: y), from: .zero, operation: .copy, fraction: 1)
        }
        sheet.unlockFocus()
        let tiff = try #require(sheet.tiffRepresentation)
        let data = try #require(
            NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

        #expect(data.count > 100_000)
        if let outputDirectory = ProcessInfo.processInfo.environment["EDITH_THEME_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("dashboard-cards.png"))
        }
    }
}

private struct DashboardCardsEvidence: View {
    let theme: AppTheme
    @Environment(\.colorScheme) private var scheme

    private var accounts: [ClaudeAccountLimits] {
        let now = Date()
        return [
            ClaudeAccountLimits(
                id: UUID(), name: "Alpha",
                limits: LimitsProviderSnapshot(
                    provider: .claude,
                    session: LimitWindow(percent: 11, resetsAt: now.addingTimeInterval(2_000)),
                    week: LimitWindow(percent: 43, resetsAt: now.addingTimeInterval(480_000)),
                    fable: LimitWindow(percent: 4, resetsAt: now.addingTimeInterval(480_000))),
                refreshedAt: now),
            ClaudeAccountLimits(
                id: UUID(), name: "Beta",
                limits: LimitsProviderSnapshot(
                    provider: .claude,
                    session: LimitWindow(percent: 72, resetsAt: now.addingTimeInterval(9_000)),
                    week: LimitWindow(percent: 28, resetsAt: now.addingTimeInterval(300_000))),
                refreshedAt: now),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("\(theme.rawValue.capitalized) theme, \(scheme == .dark ? "dark" : "light")")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("Browse months").font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.themeAccent)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) {
                    PageMetric(title: "Input", value: "0.9M", detail: "2% of tokens")
                    PageMetric(title: "Output", value: "3.8M", detail: "6% of tokens")
                }
                .frame(width: 260)
                PageCard(title: "Rate limits", note: "session · weekly") {
                    ClaudeAccountLimitsView(accounts: accounts)
                }
            }
        }
        .padding(22)
        .foregroundStyle(DashSkin.ink(scheme == .dark))
        .background(DashSkin.paper(scheme == .dark))
    }
}

private struct ThemeEvidenceView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edith theme system")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(
                    "Neutral app surfaces and terminals with theme-aware database workspaces"
                )
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(DashSkin.inkSoft(true))
            }

            HStack(spacing: 20) {
                ThemeEvidenceCard(theme: .blue)
                ThemeEvidenceCard(theme: .orange)
            }
        }
        .padding(30)
        .foregroundStyle(DashSkin.ink(true))
        .background(DashSkin.paper(true))
        .environment(\.colorScheme, .dark)
    }
}

private struct ThemeEvidenceCard: View {
    let theme: AppTheme

    private var quinjetConfiguration: QuinjetLaunchConfiguration {
        QuinjetLaunchConfiguration(
            terminal: .embedded, theme: .quinjet, appearance: .dark,
            hostTheme: .edith(appTheme: theme))
    }

    private var accent: Color {
        DashSkin.accent(true, theme: theme)
    }

    private var databasePalette: DatabaseThemePalette {
        DatabaseThemePalette(dark: true, theme: theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Circle()
                    .fill(accent)
                    .frame(width: 18, height: 18)
                Text(theme.rawValue.capitalized)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Spacer()
                Text("App theme")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Edith surfaces")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DashSkin.inkSoft(true))
                HStack(spacing: 10) {
                    SurfaceSample(title: "Page", color: DashSkin.paper(true))
                    SurfaceSample(title: "Card", color: DashSkin.paper2(true))
                    SurfaceSample(title: "Accent", color: accent)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Database workspace")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(databasePalette.inkSoft)
                HStack(spacing: 10) {
                    SurfaceSample(title: "Canvas", color: databasePalette.canvas)
                    SurfaceSample(title: "Panel", color: databasePalette.panel)
                    SurfaceSample(title: "Grid", color: databasePalette.grid)
                }
            }

            TerminalEvidence(
                title: "Ghostty and SwiftTerm",
                palette: TerminalPalette.edith(dark: true, theme: theme)
            )

            TerminalEvidence(
                title: "Quinjet app palette",
                palette: TerminalPalette.quinjet(configuration: quinjetConfiguration)
            )
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DashSkin.paper2(true), in: RoundedRectangle(cornerRadius: 18))
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(DashSkin.line(true), lineWidth: 1)
        )
    }
}

private struct SurfaceSample: View {
    let title: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(height: 42)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DashSkin.lineStrong(true), lineWidth: 1)
                )
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DashSkin.inkSoft(true))
        }
        .frame(maxWidth: .infinity)
    }
}

private struct TerminalEvidence: View {
    let title: String
    let palette: TerminalPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(nsColor: palette.foreground))
            Text("edith % theme-check")
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(nsColor: palette.foreground))
            HStack(spacing: 4) {
                ForEach(Array(palette.ansi.enumerated()), id: \.offset) { entry in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: entry.element))
                        .frame(height: 22)
                }
            }
            HStack(spacing: 7) {
                Text("selection")
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .foregroundStyle(Color(nsColor: palette.selectionForeground))
                    .background(Color(nsColor: palette.selectionBackground))
                Rectangle()
                    .fill(Color(nsColor: palette.caret))
                    .frame(width: 3, height: 19)
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
        }
        .padding(15)
        .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: palette.caret).opacity(0.5), lineWidth: 1)
        )
    }
}
