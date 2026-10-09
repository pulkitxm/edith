import EdithKit
import SwiftUI

struct SystemPage: View {
    @State private var model: RunningAppsModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact
    @State private var confirmQuitAll = false
    @State private var pendingQuit: RunningAppRow?

    init(model: RunningAppsModel? = nil) {
        _model = State(initialValue: model ?? RunningAppsModel())
    }

    private var dark: Bool { scheme == .dark }
    private var hidesRunningApps: Bool { PresenterState.shared.hides(.runningApps) }

    var body: some View {
        PageScaffold(pinnedHeader: true) {
            header
        } content: {
            if let status = model.actionStatus {
                actionStatus(status)
            }
            PageLoading(state: model.loading.state, layout: .list) {
                summary
                PageCard(title: "Running apps") {
                    appList
                }
            }
            .background(ScrollPauseMonitor { model.setScrolling($0) })
        }
        .confirmationDialog(
            hidesRunningApps ? "Quit this app?" : "Quit \(pendingQuit?.name ?? "app")?",
            isPresented: Binding(
                get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } }),
            titleVisibility: .visible
        ) {
            Button(
                hidesRunningApps ? "Quit app" : "Quit \(pendingQuit?.name ?? "app")",
                role: .destructive
            ) {
                if let app = pendingQuit { model.quit(app) }
                pendingQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingQuit = nil }
        } message: {
            Text("The app will close. Unsaved changes will prompt you first.")
        }
        .onDisappear { model.setScrolling(false) }
        .pageRefresh(interval: { .seconds(2) }, cancel: { model.loading.cancel() }) {
            if !model.scrolling { await model.refresh() }
        }
    }

    private var header: some View {
        PageHeader(
            "System",
            trailing: {
                Button(role: .destructive) {
                    confirmQuitAll = true
                } label: {
                    Label("Quit all apps", systemImage: "xmark.circle")
                }
                .buttonStyle(EdithButtonStyle(.destructive))
                .confirmationDialog(
                    "Quit all apps?", isPresented: $confirmQuitAll, titleVisibility: .visible
                ) {
                    Button("Quit \(model.quitAllTargetCount) apps", role: .destructive) {
                        model.quitAll()
                    }
                } message: {
                    Text("Finder and Edith stay open. Apps with unsaved changes will ask first.")
                }
            },
            accessory: {
                SearchField(placeholder: "Filter app, bundle identifier or PID", text: $model.query)
            })
    }

    private func actionStatus(_ status: RunningAppActionStatus) -> some View {
        let presentation = actionStatusPresentation(status)
        return HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(9)) {
            Image(systemName: presentation.symbol)
            Text(status.message)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .presenterBlur(.runningApps)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                model.clearActionStatus()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(EdithButtonStyle(.iconOnly, tint: presentation.color))
            .accessibilityLabel("Dismiss status")
            .help("Dismiss")
        }
        .foregroundStyle(presentation.color)
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(10))
        .background(
            presentation.color.opacity(dark ? 0.16 : 0.1),
            in: RoundedRectangle(cornerRadius: UIScale.pt(10))
        )
        .accessibilityElement(children: .combine)
    }

    private func actionStatusPresentation(
        _ status: RunningAppActionStatus
    ) -> (symbol: String, color: Color) {
        switch status {
        case .accepted:
            ("checkmark.circle.fill", .green)
        case .partial:
            ("exclamationmark.triangle.fill", .orange)
        case .planRejected, .planningFailed, .rejected:
            ("xmark.octagon.fill", .red)
        }
    }

    private var summary: some View {
        HStack(spacing: UIScale.pt(12)) {
            summaryCard("Running apps", "\(model.apps.count)")
            summaryCard("App memory", String(format: "%.1f GB", model.totalMemoryMB / 1024))
        }
    }

    private func summaryCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(label.uppercased())
                .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(UIScale.pt(0.6))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(value).font(.system(size: UIScale.pt(22), weight: .semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(16))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
    }

    private var columnHeaders: some View {
        HStack(spacing: UIScale.pt(10)) {
            headerButton("App", .name, width: nil, alignment: .leading)
                .padding(.leading, UIScale.pt(32))
            Spacer()
            headerButton("CPU", .cpu, width: UIScale.pt(48), alignment: .trailing)
            headerButton("Memory", .memory, width: UIScale.pt(72), alignment: .trailing)
            Color.clear.frame(width: UIScale.pt(16))
        }
        .padding(.bottom, UIScale.pt(6))
    }

    private func headerButton(
        _ label: String, _ key: AppSortKey, width: CGFloat?, alignment: Alignment
    ) -> some View {
        Button {
            model.sort(by: key)
        } label: {
            HStack(spacing: UIScale.pt(3)) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(label.uppercased())
                    .font(.system(size: UIScale.pt(10), weight: .semibold)).tracking(
                        UIScale.pt(0.5))
                if model.sortKey == key {
                    Image(systemName: model.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: UIScale.pt(7), weight: .bold))
                }
                if alignment == .leading { Spacer(minLength: 0) }
            }
            .foregroundStyle(model.sortKey == key ? DashSkin.accent(dark) : DashSkin.inkFaint(dark))
            .frame(width: width, alignment: alignment)
        }
        .buttonStyle(
            EdithButtonStyle(
                .borderless, selected: model.sortKey == key, tint: DashSkin.accent(dark))
        )
    }

    private var appList: some View {
        let apps = model.visibleApps
        return VStack(spacing: UIScale.pt(0)) {
            columnHeaders
            Divider().opacity(0.4)
            if !model.loaded {
                SystemAppRowsSkeleton(dark: dark)
            } else if apps.isEmpty {
                Text(
                    model.query.isEmpty
                        ? "No user applications are running." : "No apps match this search."
                )
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, UIScale.pt(24))
            }
            LazyVStack(spacing: UIScale.pt(0)) {
                ForEach(apps) { app in
                    SystemAppRow(app: app, dark: dark, canQuit: model.canQuit(app)) {
                        pendingQuit = app
                    }
                    if app.id != apps.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }

    fileprivate static func cpuLabel(_ percent: Double) -> String {
        percent >= 10 || percent == 0
            ? String(format: "%.0f%%", percent) : String(format: "%.1f%%", percent)
    }

    fileprivate static func memoryLabel(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }
}

private struct SystemSummarySkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(12)) {
                ForEach(0..<2, id: \.self) { index in
                    VStack(alignment: .leading, spacing: UIScale.pt(7)) {
                        SkeletonBlock(width: index == 0 ? 82 : 74, height: 8)
                        SkeletonBlock(width: index == 0 ? 42 : 88, height: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(UIScale.pt(16))
                    .background(
                        DashSkin.paper2(dark),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
                }
            }
        }
        .accessibilityLabel("Reading system summary")
    }
}

private struct SystemAppRowsSkeleton: View {
    let dark: Bool

    var body: some View {
        SkeletonGroup {
            VStack(spacing: UIScale.pt(0)) {
                ForEach(0..<6, id: \.self) { index in
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 22, height: 22, corner: 6)
                        SkeletonBlock(
                            width: index.isMultiple(of: 2) ? 126 : 174,
                            height: 10)
                        Spacer()
                        SkeletonBlock(width: 38, height: 9)
                            .frame(width: UIScale.pt(48), alignment: .trailing)
                        SkeletonBlock(width: 58, height: 9)
                            .frame(width: UIScale.pt(72), alignment: .trailing)
                        SkeletonBlock(width: 16, height: 16, corner: 8)
                    }
                    .padding(.horizontal, UIScale.pt(6))
                    .padding(.vertical, UIScale.pt(7))
                    if index < 5 { Divider().opacity(0.3) }
                }
            }
        }
        .accessibilityLabel("Reading running apps")
    }
}

private struct ScrollPauseMonitor: NSViewRepresentable {
    var onChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> Monitor {
        Monitor(onChange: onChange)
    }

    func updateNSView(_ view: Monitor, context: Context) {
        view.onChange = onChange
    }

    final class Monitor: NSView {
        var onChange: @MainActor (Bool) -> Void
        private var observers: [NSObjectProtocol] = []

        init(onChange: @escaping @MainActor (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            guard let scroll = enclosingScrollView else { return }
            let center = NotificationCenter.default
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didLiveScrollNotification, object: scroll, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(true) }
                })
            observers.append(
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onChange(false) }
                })
        }
    }
}

struct SystemAppRow: View {
    let app: RunningAppRow
    let dark: Bool
    let canQuit: Bool
    let onQuit: () -> Void
    @State private var hovering = false

    private var hidesName: Bool { PresenterState.shared.hides(.runningApps) }

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(
                        width: UIScale.pt(22), height: UIScale.pt(22))
                } else {
                    Image(systemName: "app.fill")
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .frame(width: UIScale.pt(22), height: UIScale.pt(22))
                }
            }
            .presenterCover(.runningApps)
            Text(app.name).font(.system(size: UIScale.pt(13))).lineLimit(1)
                .presenterBlur(.runningApps)
            Spacer()
            Text(SystemPage.cpuLabel(app.cpuPercent))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(app.cpuPercent > 25 ? .orange : DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(48), alignment: .trailing)
            Text(SystemPage.memoryLabel(app.memoryMB))
                .font(.system(size: UIScale.pt(12), design: .monospaced))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .frame(width: UIScale.pt(72), alignment: .trailing)
            Button {
                onQuit()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(EdithButtonStyle(.iconOnly, tint: DashSkin.accent(dark)))
            .disabled(!canQuit)
            .accessibilityLabel(hidesName ? "Quit app" : "Quit \(app.name)")
            .help(
                hidesName
                    ? (canQuit ? "Quit app" : "This app stays open")
                    : (canQuit ? "Quit \(app.name)" : "\(app.name) stays open"))
        }
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(7))
        .background(
            RoundedRectangle(cornerRadius: UIScale.pt(7))
                .fill(hovering ? DashSkin.inkFaint(dark).opacity(0.1) : .clear)
        )
        .onHover { hovering = $0 }
    }
}
