import EdithKit
import SwiftUI

enum HerdrAgentTerminalSkeletonFlavor: String, CaseIterable {
    case claudeCode
    case codex
    case openCode
    case cursorAgent
    case copilotCLI
    case pi
    case gemini
    case grok
    case cline
    case fx
    case generic

    init(kind: String) {
        switch HerdrKind.displayName(for: kind) {
        case "Claude Code": self = .claudeCode
        case "Codex": self = .codex
        case "OpenCode": self = .openCode
        case "Cursor Agent": self = .cursorAgent
        case "Copilot CLI": self = .copilotCLI
        case "Pi": self = .pi
        case "Gemini": self = .gemini
        case "Grok": self = .grok
        case "Cline": self = .cline
        case "FX.sh": self = .fx
        default: self = .generic
        }
    }
}

struct HerdrAgentTerminalSkeleton: View {
    let kind: String
    let palette: TerminalPalette

    private var flavor: HerdrAgentTerminalSkeletonFlavor {
        HerdrAgentTerminalSkeletonFlavor(kind: kind)
    }

    var body: some View {
        SkeletonGroup {
            chrome
                .padding(.horizontal, UIScale.pt(14))
                .padding(.vertical, UIScale.pt(12))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: palette.background))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading \(HerdrKind.displayName(for: kind)) terminal")
    }

    @ViewBuilder
    private var chrome: some View {
        switch flavor {
        case .claudeCode: claudeCodeChrome
        case .codex: codexChrome
        case .openCode: openCodeChrome
        case .cursorAgent: cursorAgentChrome
        case .copilotCLI: copilotChrome
        case .pi: piChrome
        case .gemini: geminiChrome
        case .grok: grokChrome
        case .cline: clineChrome
        case .fx: fxChrome
        case .generic: TerminalLoadingSkeleton(palette: palette)
        }
    }

    private var claudeCodeChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            outputRows([228, 314, 184])
            Spacer(minLength: UIScale.pt(24))
            rule
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 12, height: 15, corner: 2)
                SkeletonBlock(width: 182, height: 10, corner: 2)
            }
            .frame(height: UIScale.pt(42))
            rule
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 20, height: 9, corner: 2)
                SkeletonBlock(width: 244, height: 9, corner: 2)
            }
            SkeletonBlock(width: 176, height: 9, corner: 2)
        }
    }

    private var codexChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 22, height: 14, corner: 2)
                    SkeletonBlock(width: 118, height: 13, corner: 2)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 58, height: 9, corner: 2)
                }
                Spacer().frame(height: UIScale.pt(4))
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 54, height: 9, corner: 2)
                    SkeletonBlock(width: 104, height: 9, corner: 2)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 92, height: 8, corner: 2)
                }
                HStack(spacing: UIScale.pt(12)) {
                    SkeletonBlock(width: 68, height: 9, corner: 2)
                    SkeletonBlock(width: 234, height: 9, corner: 2)
                }
            }
            .padding(UIScale.pt(12))
            .frame(width: UIScale.pt(410))
            .frame(minHeight: UIScale.pt(108), alignment: .topLeading)
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(Color.primary.opacity(0.13))
            }
            Spacer(minLength: UIScale.pt(12))
            HStack(spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 10, height: 14, corner: 2)
                SkeletonBlock(width: 196, height: 10, corner: 2)
            }
            .padding(.horizontal, UIScale.pt(2))
            .frame(height: UIScale.pt(36))
            SkeletonBlock(width: 92, height: 8, corner: 2)
                .padding(.leading, UIScale.pt(18))
        }
    }

    private var openCodeChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            outputRows([246, 328, 194, 286])
            Spacer(minLength: UIScale.pt(22))
            HStack(spacing: UIScale.pt(10)) {
                Rectangle()
                    .fill(Color(nsColor: palette.caret).opacity(0.7))
                    .frame(width: UIScale.pt(2))
                VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 212, height: 10, corner: 2)
                    SkeletonBlock(width: 134, height: 9, corner: 2)
                }
            }
            .padding(UIScale.pt(11))
            .frame(minHeight: UIScale.pt(58), alignment: .leading)
            .background(Color.primary.opacity(0.045))
            HStack(spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 252, height: 8, corner: 2)
                Spacer(minLength: 0)
                SkeletonBlock(width: 74, height: 8, corner: 2)
                SkeletonBlock(width: 92, height: 8, corner: 2)
            }
        }
    }

    private var cursorAgentChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 18, height: 18, corner: 4)
                SkeletonBlock(width: 104, height: 12, corner: 2)
                Spacer(minLength: 0)
                SkeletonBlock(width: 82, height: 9, corner: 2)
            }
            outputRows([202, 294, 156])
            Spacer(minLength: UIScale.pt(20))
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 216, height: 10, corner: 2)
                Spacer(minLength: 0)
                HStack {
                    SkeletonBlock(width: 88, height: 8, corner: 2)
                    Spacer()
                    SkeletonBlock(width: 66, height: 8, corner: 2)
                }
            }
            .padding(UIScale.pt(12))
            .frame(minHeight: UIScale.pt(76), alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(Color.primary.opacity(0.13))
            }
        }
    }

    private var copilotChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 28, height: 28, corner: 7)
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    SkeletonBlock(width: 146, height: 13, corner: 2)
                    SkeletonBlock(width: 224, height: 9, corner: 2)
                }
            }
            outputRows([186, 276])
            Spacer(minLength: UIScale.pt(24))
            rule
            HStack(spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 10, height: 14, corner: 2)
                SkeletonBlock(width: 214, height: 10, corner: 2)
            }
            .frame(height: UIScale.pt(42))
            HStack(spacing: UIScale.pt(12)) {
                SkeletonBlock(width: 78, height: 8, corner: 2)
                SkeletonBlock(width: 96, height: 8, corner: 2)
            }
        }
    }

    private var piChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            outputRows([164, 302, 218, 268])
            Spacer(minLength: UIScale.pt(24))
            rule
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 7, height: 14, corner: 1)
                SkeletonBlock(width: 148, height: 10, corner: 2)
            }
            .frame(height: UIScale.pt(44))
            rule
            SkeletonBlock(width: 268, height: 8, corner: 2)
            HStack(spacing: UIScale.pt(10)) {
                SkeletonBlock(width: 238, height: 8, corner: 2)
                Spacer(minLength: 0)
                SkeletonBlock(width: 88, height: 8, corner: 2)
            }
        }
    }

    private var geminiChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(10)) {
                SkeletonBlock(width: 26, height: 26, corner: 8)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    SkeletonBlock(width: 92, height: 14, corner: 2)
                    SkeletonBlock(width: 166, height: 8, corner: 2)
                }
            }
            outputRows([238, 176])
            Spacer(minLength: UIScale.pt(24))
            HStack(spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 12, height: 16, corner: 3)
                SkeletonBlock(width: 204, height: 10, corner: 2)
            }
            .padding(UIScale.pt(12))
            .frame(minHeight: UIScale.pt(58), alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .strokeBorder(Color.primary.opacity(0.13))
            }
            SkeletonBlock(width: 144, height: 8, corner: 2)
        }
    }

    private var grokChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                SkeletonBlock(width: 72, height: 15, corner: 2)
                Spacer()
                SkeletonBlock(width: 84, height: 9, corner: 2)
            }
            outputRows([286, 194, 242])
            Spacer(minLength: UIScale.pt(22))
            rule
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 11, height: 14, corner: 2)
                SkeletonBlock(width: 226, height: 10, corner: 2)
            }
            .frame(height: UIScale.pt(46))
            HStack {
                SkeletonBlock(width: 118, height: 8, corner: 2)
                Spacer()
                SkeletonBlock(width: 66, height: 8, corner: 2)
            }
        }
    }

    private var clineChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 20, height: 20, corner: 5)
                SkeletonBlock(width: 76, height: 13, corner: 2)
            }
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 184, height: 10, corner: 2)
                SkeletonBlock(width: 302, height: 9, corner: 2)
                SkeletonBlock(width: 246, height: 9, corner: 2)
            }
            .padding(UIScale.pt(12))
            .background(Color.primary.opacity(0.04))
            Spacer(minLength: UIScale.pt(22))
            VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                SkeletonBlock(width: 226, height: 10, corner: 2)
                HStack {
                    SkeletonBlock(width: 94, height: 8, corner: 2)
                    Spacer()
                    SkeletonBlock(width: 26, height: 22, corner: 6)
                }
            }
            .padding(UIScale.pt(12))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(9))
                    .strokeBorder(Color.primary.opacity(0.13))
            }
        }
    }

    private var fxChrome: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 24, height: 17, corner: 3)
                SkeletonBlock(width: 198, height: 9, corner: 2)
            }
            HStack(spacing: UIScale.pt(9)) {
                Rectangle()
                    .fill(Color(nsColor: palette.caret).opacity(0.7))
                    .frame(width: UIScale.pt(3), height: UIScale.pt(26))
                SkeletonBlock(width: 186, height: 10, corner: 2)
            }
            Spacer(minLength: UIScale.pt(24))
            HStack(spacing: UIScale.pt(8)) {
                SkeletonBlock(width: 34, height: 9, corner: 2)
                SkeletonBlock(width: 104, height: 9, corner: 2)
            }
        }
    }

    private var rule: some View {
        SkeletonBlock(height: 1, corner: 0)
    }

    private func outputRows(_ widths: [Double]) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            ForEach(Array(widths.enumerated()), id: \.offset) { index, width in
                HStack(spacing: UIScale.pt(8)) {
                    if index.isMultiple(of: 2) {
                        SkeletonBlock(width: 8, height: 8, corner: 2)
                    }
                    SkeletonBlock(width: width, height: 9, corner: 2)
                }
            }
        }
    }
}
