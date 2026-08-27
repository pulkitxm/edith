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

private struct ThemeEvidenceView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Edith theme system")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text(
                    "Constant app surfaces with dynamic accents, Quinjet themes, and terminal palettes"
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
