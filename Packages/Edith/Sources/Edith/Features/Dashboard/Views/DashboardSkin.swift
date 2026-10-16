import AppKit
import EdithKit
import SwiftUI

private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var compactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

struct LazyChartCard<Content: View>: View {
    let title: String
    var note: String? = nil
    let dark: Bool
    var placeholderHeight: CGFloat = UIScale.pt(224)
    @ViewBuilder var content: () -> Content
    @State private var loaded = false

    var body: some View {
        PageCard(title: title, note: note) {
            Group {
                if loaded {
                    content()
                } else {
                    SkeletonGroup {
                        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
                            HStack(alignment: .bottom, spacing: UIScale.pt(6)) {
                                ForEach(0..<12, id: \.self) { index in
                                    SkeletonBlock(
                                        height: CGFloat(32 + index % 5 * 22),
                                        corner: 3)
                                }
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            HStack {
                                SkeletonBlock(width: 58, height: 8)
                                Spacer()
                                SkeletonBlock(width: 58, height: 8)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: placeholderHeight)
                    .accessibilityLabel("Loading \(title)")
                }
            }
        }
        .task {
            guard !loaded else { return }
            await Task.yield()
            loaded = true
        }
    }
}
