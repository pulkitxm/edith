import EdithExtensionSupport
import SwiftUI

public struct PageCard<Content: View>: View {
    var title: String?
    var note: String?
    var fill = false
    @ViewBuilder let content: () -> Content

    public init(
        title: String? = nil, note: String? = nil, fill: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.note = note
        self.fill = fill
        self.content = content
    }

    public var body: some View {
        PagePanel(fill: fill) {
            if let title {
                PageSectionHeader(title) {
                    if let note {
                        Text(note).font(.edithText(.caption)).foregroundStyle(.secondary)
                    }
                }
            }
        } content: {
            content()
        }
    }
}

public struct PagePanel<Header: View, Content: View>: View {
    var fill = false
    @ViewBuilder let header: () -> Header
    @ViewBuilder let content: () -> Content

    public init(
        fill: Bool = false, @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.fill = fill
        self.header = header
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(PageMetrics.cardSpacing)) {
            header()
            content()
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
        .edithSurface(cornerRadius: 14)
    }
}
