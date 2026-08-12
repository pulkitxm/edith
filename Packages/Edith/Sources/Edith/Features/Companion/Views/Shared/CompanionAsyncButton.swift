import EdithKit
import SwiftUI

struct CompanionAsyncButton: View {
    private let title: String
    private let filled: Bool
    private let disabled: Bool
    private let action: () async -> Void
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    init(
        _ title: String,
        filled: Bool = false,
        disabled: Bool = false,
        action: @escaping () async -> Void
    ) {
        self.title = title
        self.filled = filled
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Text(title)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .padding(.horizontal, UIScale.pt(11))
                .padding(.vertical, UIScale.pt(6))
                .foregroundStyle(filled ? DashSkin.paper(dark) : DashSkin.ink(dark))
                .background {
                    RoundedRectangle(cornerRadius: UIScale.pt(8))
                        .fill(filled ? DashSkin.accent(dark) : DashSkin.paper2(dark))
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .disabled(disabled)
    }
}
