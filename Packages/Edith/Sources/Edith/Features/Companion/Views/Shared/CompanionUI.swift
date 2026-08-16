import EdithKit
import SwiftUI

enum CompanionMetrics {
    static var columnWidth: CGFloat { UIScale.pt(680) }
    static var cardSpacing: CGFloat { UIScale.pt(16) }
    static var rowSpacing: CGFloat { UIScale.pt(10) }
    static var twoColumnThreshold: CGFloat { UIScale.pt(1020) }
}

struct CompanionGrid<Primary: View, Secondary: View, Full: View>: View {
    let width: CGFloat
    @ViewBuilder var primary: () -> Primary
    @ViewBuilder var secondary: () -> Secondary
    @ViewBuilder var full: () -> Full

    private var wide: Bool { width >= CompanionMetrics.twoColumnThreshold }

    var body: some View {
        VStack(alignment: .leading, spacing: CompanionMetrics.cardSpacing) {
            if wide {
                HStack(alignment: .top, spacing: CompanionMetrics.cardSpacing) {
                    VStack(alignment: .leading, spacing: CompanionMetrics.cardSpacing) {
                        primary()
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: CompanionMetrics.cardSpacing) {
                        secondary()
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                primary()
                secondary()
            }
            full()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct CompanionButton: View {
    enum Role {
        case primary
        case normal
        case destructive
    }

    let title: String
    var role: Role = .normal
    var busy = false
    var busyTitle: String? = nil
    var disabled = false
    var help: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var dark: Bool { scheme == .dark }
    private var inactive: Bool { disabled || busy }

    private var labelColor: Color {
        switch role {
        case .primary: return DashSkin.paper(dark)
        case .normal: return DashSkin.ink(dark)
        case .destructive: return DashSkin.danger
        }
    }

    private var fillColor: Color {
        switch role {
        case .primary:
            return hovering && !inactive ? DashSkin.accentDeep(dark) : DashSkin.accent(dark)
        case .normal, .destructive:
            return hovering && !inactive
                ? DashSkin.line(dark).opacity(0.45) : DashSkin.paper(dark).opacity(0.6)
        }
    }

    private var borderColor: Color {
        switch role {
        case .primary: return .clear
        case .normal: return DashSkin.lineStrong(dark)
        case .destructive: return DashSkin.danger.opacity(0.55)
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: UIScale.pt(6)) {
                if busy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                        .frame(width: UIScale.pt(12), height: UIScale.pt(12))
                }
                Text(busy ? (busyTitle ?? title) : title)
                    .font(.system(size: UIScale.pt(12), weight: .medium))
            }
            .foregroundStyle(labelColor)
            .padding(.horizontal, UIScale.pt(12))
            .frame(minHeight: UIScale.pt(26))
            .background {
                RoundedRectangle(cornerRadius: UIScale.pt(8)).fill(fillColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(8))
                    .strokeBorder(borderColor, lineWidth: UIScale.pt(1))
            }
            .opacity(inactive ? 0.55 : 1)
            .contentShape(RoundedRectangle(cornerRadius: UIScale.pt(8)))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(inactive)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: busy)
        .help(help ?? "")
    }
}

struct CompanionLinkButton: View {
    let title: String
    var destructive = false
    var disabled = false
    var help: String? = nil
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(destructive ? DashSkin.danger : DashSkin.accent(dark))
                .underline(hovering && !disabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

struct CompanionFieldLabel: View {
    let text: String
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: UIScale.pt(9.5), weight: .semibold))
            .tracking(UIScale.pt(0.9))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }
}

struct CompanionLabeledField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var help: String? = nil
    var error: String? = nil
    var onSubmit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            CompanionFieldLabel(text: label)
            EdithTextField(
                placeholder: placeholder, text: $text, invalid: error != nil,
                onSubmit: onSubmit)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.danger)
            } else if let help {
                Text(help)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }
}

struct CompanionSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var detail: String? = nil
    var detailEmphasis = false
    var clear: (() -> Void)? = nil
    var clearDisabled = false
    var onSubmit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(8)) {
                CompanionFieldLabel(text: label)
                Spacer(minLength: 0)
                if let detail {
                    Text(detail)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(
                            detailEmphasis ? DashSkin.inkSoft(dark) : DashSkin.inkFaint(dark)
                        )
                        .lineLimit(1)
                }
                if let clear {
                    CompanionLinkButton(
                        title: "Clear", destructive: false, disabled: clearDisabled,
                        help: "Remove the stored token", action: clear)
                }
            }
            SecureField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.ink(dark))
                .focused($focused)
                .focusEffectDisabled()
                .onSubmit { onSubmit?() }
                .edithFieldSurface(focused: focused)
        }
    }
}

struct AnswerField: View {
    let placeholder: String
    @Binding var text: String
    var submit: (() -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(2...6)
            .font(.system(size: UIScale.pt(12.5)))
            .foregroundStyle(DashSkin.ink(dark))
            .focused($focused)
            .focusEffectDisabled()
            .onSubmit { submit?() }
            .edithFieldSurface(focused: focused)
    }
}

struct CompanionStatusLine: View {
    enum Tone {
        case ok
        case info
        case error
    }

    let text: String
    var tone: Tone = .info

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    private var icon: String {
        switch tone {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch tone {
        case .ok: return DashSkin.ok
        case .info: return DashSkin.inkFaint(dark)
        case .error: return DashSkin.warn
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(5)) {
            Image(systemName: icon)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(tone == .info ? DashSkin.inkFaint(dark) : DashSkin.inkSoft(dark))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity)
    }
}

struct CompanionDangerRow: View {
    let title: String
    let consequence: String
    let buttonTitle: String
    var busy = false
    var disabled = false
    let action: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                    .font(.system(size: UIScale.pt(12.5), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text(consequence)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: UIScale.pt(12))
            CompanionButton(
                title: buttonTitle, role: .destructive, busy: busy, disabled: disabled,
                action: action)
        }
        .padding(.vertical, UIScale.pt(8))
    }
}

struct CompanionConfirmSheet: View {
    let title: String
    let message: String
    let phrase: String
    let actionTitle: String
    let confirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var dark: Bool { scheme == .dark }
    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespaces).uppercased() == phrase.uppercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            HStack(spacing: UIScale.pt(10)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: UIScale.pt(20)))
                    .foregroundStyle(DashSkin.danger)
                Text(title)
                    .font(DashSkin.serif(20))
                    .foregroundStyle(DashSkin.ink(dark))
            }
            Text(message)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                CompanionFieldLabel(text: "Type \(phrase) to continue")
                EdithTextField(
                    placeholder: phrase, text: $typed,
                    onSubmit: {
                        guard matches else { return }
                        dismiss()
                        confirm()
                    })
            }
            HStack {
                Spacer()
                CompanionButton(title: "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                CompanionButton(
                    title: actionTitle, role: .destructive, disabled: !matches
                ) {
                    dismiss()
                    confirm()
                }
            }
        }
        .padding(UIScale.pt(20))
        .frame(width: UIScale.pt(400))
        .background(DashSkin.paper(dark))
    }
}

struct CompanionCardSkeleton: View {
    var rows: Int = 3
    let dark: Bool

    var body: some View {
        SkinCard(title: " ", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                ForEach(0..<rows, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        SkeletonBlock(width: index.isMultiple(of: 2) ? 72 : 96, height: 8)
                        SkeletonBlock(height: 26, corner: 9)
                    }
                }
                HStack(spacing: UIScale.pt(8)) {
                    SkeletonBlock(width: 64, height: 24, corner: 8)
                    SkeletonBlock(width: 104, height: 24, corner: 8)
                }
            }
        }
    }
}
