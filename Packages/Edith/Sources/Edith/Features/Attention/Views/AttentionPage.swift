import EdithKit
import SwiftUI

struct AttentionPage: View {
    @State private var store = AttentionMockStore()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compactLayout

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DashSkin.line(dark))
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    content
                }
                .pageContent(compactLayout)
                .padding(.top, UIScale.pt(16))
            }
        }
        .background(background)
        .overlay(alignment: .bottom) { toast }
        .navigationTitle("Attention")
    }

    private var background: some View {
        DashSkin.paper(dark)
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [DashSkin.accent(dark).opacity(0.08), .clear],
                    center: .topTrailing, startRadius: 0, endRadius: UIScale.pt(620))
            }
            .ignoresSafeArea(edges: .vertical)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(13)) {
            HStack(alignment: .center, spacing: UIScale.pt(12)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    HStack(spacing: UIScale.pt(9)) {
                        Text("Attention")
                            .font(PageMetrics.titleFont(compactLayout))
                            .foregroundStyle(DashSkin.ink(dark))
                        AttentionBadge(text: "INTERACTIVE MOCK", color: DashSkin.accentDeep(dark))
                    }
                    Text("One month of local context, presence, media, intent, and delegated work")
                        .font(.system(size: UIScale.pt(11.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
                Spacer(minLength: UIScale.pt(8))
                HStack(spacing: UIScale.pt(7)) {
                    Button {
                        store.recordingPaused.toggle()
                        store.toast =
                            store.recordingPaused
                            ? "Mock recording paused" : "Mock recording resumed"
                    } label: {
                        Label(
                            store.recordingPaused ? "Resume" : "Recording",
                            systemImage: store.recordingPaused
                                ? "pause.circle.fill" : "record.circle"
                        )
                        .font(.system(size: UIScale.pt(11), weight: .medium))
                        .foregroundStyle(store.recordingPaused ? DashSkin.warn : DashSkin.sage)
                        .padding(.horizontal, UIScale.pt(10))
                        .frame(height: UIScale.pt(28))
                        .background(DashSkin.paper2(dark), in: Capsule())
                        .overlay(Capsule().strokeBorder(DashSkin.line(dark)))
                    }
                    .buttonStyle(.plain)
                    .pointerCursor()
                    Button {
                        store.resetSetup()
                    } label: {
                        Image(systemName: "wand.and.stars")
                            .frame(width: UIScale.pt(28), height: UIScale.pt(28))
                            .background(DashSkin.paper2(dark), in: Circle())
                            .overlay(Circle().strokeBorder(DashSkin.line(dark)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .help("Run guided setup")
                    .pointerCursor()
                }
            }
            HStack(spacing: UIScale.pt(10)) {
                AttentionSectionTabs(store: store)
                Spacer(minLength: UIScale.pt(8))
                AttentionRangePicker(store: store)
            }
        }
        .pageGutter(compactLayout)
        .padding(.top, UIScale.pt(16))
        .padding(.bottom, UIScale.pt(12))
    }

    @ViewBuilder
    private var content: some View {
        switch store.selectedSection {
        case .overview: AttentionOverviewView(store: store)
        case .timeline: AttentionTimelineView(store: store)
        case .insights: AttentionInsightsView(store: store)
        case .focus: AttentionFocusView(store: store)
        case .library: AttentionLibraryView(store: store)
        case .music: AttentionMusicView(store: store)
        case .settings: AttentionPrototypePlaceholder(section: store.selectedSection)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let toast = store.toast {
            Text(toast)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(14))
                .frame(height: UIScale.pt(34))
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(DashSkin.line(dark)))
                .padding(.bottom, UIScale.pt(16))
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: toast) {
                    try? await Task.sleep(for: .seconds(2.4))
                    if store.toast == toast { store.toast = nil }
                }
        }
    }
}
