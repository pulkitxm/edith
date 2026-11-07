import EdithExtensionCore
import SwiftUI

public enum ContentLoadingState: Equatable, Sendable {
    case loading
    case content
    case empty
    case error
    case offline
    case cancelled

    public var presentsContent: Bool {
        switch self {
        case .content: true
        case .loading, .empty, .error, .offline, .cancelled: false
        }
    }

    public var permitsRetry: Bool {
        switch self {
        case .empty, .error, .offline, .cancelled: true
        case .loading, .content: false
        }
    }
}

public enum ContentActivity: Equatable, Sendable {
    case idle
    case refreshing
    case updating

    public static func resolve(updating: Bool, refreshing: Bool) -> ContentActivity {
        updating ? .updating : refreshing ? .refreshing : .idle
    }

    public var label: String? {
        switch self {
        case .idle: nil
        case .refreshing: "Refreshing"
        case .updating: "Updating results"
        }
    }
}

public enum ContentActivityTiming {
    public static let revealDelay = Duration.milliseconds(180)
    public static let placeholderDelay = Duration.milliseconds(250)
}

public struct ContentActivityBadge: View {
    public let activity: ContentActivity
    @State private var shown = ContentActivity.idle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ activity: ContentActivity) { self.activity = activity }

    public var body: some View {
        ZStack {
            if let label = shown.label {
                LoadingIndicator(label)
                    .padding(.horizontal, UIScale.pt(10))
                    .padding(.vertical, UIScale.pt(5))
                    .background(DashSkin.panel, in: Capsule())
                    .overlay(Capsule().strokeBorder(.separator.opacity(0.6)))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .allowsHitTesting(false)
            }
        }
        .animation(Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: shown)
        .task(id: activity) {
            if activity != .idle, shown == .idle {
                try? await Task.sleep(for: ContentActivityTiming.revealDelay)
                guard !Task.isCancelled else { return }
            }
            shown = activity
        }
    }
}

enum ContentStatusCopy {
    static let errorTitle = "Couldn’t load content"
}

public struct LoadingContainer<Content: View, Placeholder: View>: View {
    public let state: ContentLoadingState
    public let title: String
    public let message: String
    public let retry: (() -> Void)?
    public let cancel: (() -> Void)?
    public let refreshing: Bool
    public let updating: Bool
    private let errorTitle: String?
    @State private var dimmed = false
    private let content: () -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: ContentLoadingState,
        title: String? = nil,
        errorTitle: String? = nil,
        message: String = "There is nothing to show yet.",
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        refreshing: Bool = false,
        updating: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.state = state
        self.title = title ?? "No Content"
        self.errorTitle = errorTitle ?? title
        self.message = message
        self.retry = retry
        self.cancel = cancel
        self.refreshing = refreshing
        self.updating = updating
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            if state.presentsContent {
                content()
                    .opacity(dimmed ? 0.45 : 1)
                    .saturation(dimmed ? 0.4 : 1)
                    .accessibilityValue(dimmed ? "Updating results" : "")
                    .overlay(alignment: .topTrailing) {
                        ContentActivityBadge(refreshing && !updating ? .refreshing : .idle)
                            .padding(UIScale.pt(8))
                    }
            } else if state == .loading {
                DeferredPlaceholder { SkeletonGroup { placeholder() } }
            } else {
                unavailable
            }
        }
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state
        )
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: dimmed
        )
        .task(id: updating) {
            if updating, !dimmed {
                try? await Task.sleep(for: ContentActivityTiming.revealDelay)
                guard !Task.isCancelled else { return }
            }
            dimmed = updating
        }
    }

    private var unavailable: some View {
        ContentStatusView(
            unavailableTitle, message: message, icon: unavailableIcon,
            actionTitle: "Retry", action: state.permitsRetry ? retry : nil,
            secondaryTitle: "Cancel", secondaryAction: cancel)
    }

    var unavailableTitle: String {
        switch state {
        case .offline: "You’re offline"
        case .error: errorTitle ?? ContentStatusCopy.errorTitle
        case .cancelled: "Loading cancelled"
        default: title
        }
    }

    private var unavailableIcon: EdithIcon {
        switch state {
        case .offline: .wifiOff
        case .error: .warning
        case .cancelled: .closeFilled
        default: .tray
        }
    }
}

extension LoadingContainer where Placeholder == PageSkeleton {
    public init(
        state: ContentLoadingState,
        title: String? = nil,
        errorTitle: String? = nil,
        message: String = "There is nothing to show yet.",
        layout: PageSkeletonLayout = .list,
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        refreshing: Bool = false,
        updating: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            state: state, title: title, errorTitle: errorTitle, message: message, retry: retry,
            cancel: cancel,
            refreshing: refreshing, updating: updating, content: content,
            placeholder: { PageSkeleton(layout: layout) })
    }
}

public struct ContentStatusView: View {
    public let title: String
    public let message: String
    public let icon: EdithIcon
    public let actionTitle: String
    public let action: (() -> Void)?
    public let secondaryTitle: String
    public let secondaryAction: (() -> Void)?

    public init(
        _ title: String, message: String, icon: EdithIcon = .tray,
        actionTitle: String = "Retry", action: (() -> Void)? = nil,
        secondaryTitle: String = "Cancel", secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    public var body: some View {
        PageEmptyState(
            icon: icon, title: title, message: message, tint: tint,
            leading: secondaryAction.map { PageAction(secondaryTitle, perform: $0) },
            trailing: action.map {
                PageAction(actionTitle, icon: .refresh, perform: $0)
            }
        )
        .frame(minHeight: UIScale.pt(260))
    }

    private var tint: Color? {
        switch icon {
        case .warning, .error: .orange
        case .wifiOff, .closeFilled, .tray: .secondary
        default: nil
        }
    }
}

private struct SkeletonGroupActiveKey: EnvironmentKey {
    static let defaultValue = false
}

private struct LoadingAnimationsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    public var loadingAnimationsEnabled: Bool {
        get { self[LoadingAnimationsEnabledKey.self] }
        set { self[LoadingAnimationsEnabledKey.self] = newValue }
    }
}

private struct SkeletonPhaseKey: EnvironmentKey {
    static let defaultValue = 0.0
}

private extension EnvironmentValues {
    var skeletonGroupActive: Bool {
        get { self[SkeletonGroupActiveKey.self] }
        set { self[SkeletonGroupActiveKey.self] = newValue }
    }

    var skeletonPhase: Double {
        get { self[SkeletonPhaseKey.self] }
        set { self[SkeletonPhaseKey.self] = newValue }
    }
}

public struct SkeletonGroup<Content: View>: View {
    @ViewBuilder public let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.skeletonGroupActive) private var hasParentGroup
    @Environment(\.skeletonPhase) private var parentPhase
    @Environment(\.loadingAnimationsEnabled) private var animationsEnabled

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        if hasParentGroup {
            content
                .environment(\.skeletonPhase, parentPhase)
        } else {
            TimelineView(
                .animation(
                    minimumInterval: 1.0 / 30,
                    paused: reduceMotion || !animationsEnabled || scenePhase != .active)
            ) { context in
                content
                    .environment(\.skeletonPhase, LoadingMotion.phase(at: context.date))
                    .environment(\.skeletonGroupActive, true)
            }
        }
    }
}

public enum LoadingMotion {
    public static let duration = 1.4

    public static func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: duration) / duration
    }
}

private struct LoadingShimmer: View {
    @Environment(\.loadingAnimationsEnabled) private var animationsEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonPhase) private var phase
    @AppStorage(AppStorageKeys.General.theme, store: ExtensionScope.process.defaults())
    private var themeName = AppTheme.standard.rawValue

    var body: some View {
        if !reduceMotion, animationsEnabled {
            GeometryReader { proxy in
                LinearGradient(
                    colors: [.clear, themeColor(themeName).opacity(0.18), .clear],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: proxy.size.width * 0.45)
                .offset(x: proxy.size.width * (phase * 1.45 - 0.45))
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }
}

public struct LoadingIndicator: View {
    public let label: String?

    public init(_ label: String? = nil) { self.label = label }

    public var body: some View {
        SkeletonGroup {
            HStack(spacing: UIScale.pt(6)) {
                SkeletonBlock(width: 16, height: 16, corner: 8)
                if let label {
                    Text(label).font(.edithText(.caption)).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label ?? "Loading")
    }
}

public struct LoadingProgress: View {
    public let value: Double
    public var total: Double = 1
    public var tint: Color?
    @Environment(\.colorScheme) private var scheme

    public init(value: Double, total: Double = 1, tint: Color? = nil) {
        self.value = value
        self.total = total
        self.tint = tint
    }

    public var body: some View {
        GeometryReader { proxy in
            Capsule().fill(DashSkin.line(scheme == .dark))
                .overlay(alignment: .leading) {
                    Capsule().fill(tint ?? DashSkin.accent(scheme == .dark))
                        .frame(width: proxy.size.width * fraction)
                }
        }
        .frame(height: UIScale.pt(6))
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }

    public var fraction: Double {
        guard value.isFinite, total.isFinite, total > 0 else { return 0 }
        return min(max(value / total, 0), 1)
    }
}

public struct SkeletonReplica<Content: View>: View {
    public let label: String
    @ViewBuilder public let content: Content

    public init(_ label: String = "Loading", @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    public var body: some View {
        content.skeletonized()
            .disabled(true)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}

public extension View {
    func skeletonized() -> some View {
        modifier(SkeletonReplicaModifier())
    }
}

private struct SkeletonReplicaModifier: ViewModifier {
    func body(content: Content) -> some View {
        SkeletonGroup {
            content
                .redacted(reason: .placeholder)
                .opacity(0.58)
                .overlay {
                    LoadingShimmer().mask(content.redacted(reason: .placeholder))
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

public struct SkeletonBlock: View {
    public var width: Double?
    public var height: Double
    public var corner: Double

    public init(width: Double? = nil, height: Double = 12, corner: Double = 5) {
        self.width = width
        self.height = height
        self.corner = corner
    }

    private var scaledWidth: CGFloat? {
        guard let width else { return nil }
        return CGFloat(UIScale.pt(width))
    }

    public var body: some View {
        SkeletonSurface(shape: RoundedRectangle(cornerRadius: UIScale.pt(corner)))
            .frame(width: scaledWidth, height: UIScale.pt(height))
    }
}

struct SkeletonSurface<Outline: Shape>: View {
    let shape: Outline

    var body: some View {
        shape
            .fill(Color.primary.opacity(0.07))
            .overlay { LoadingShimmer().mask(shape) }
            .accessibilityHidden(true)
    }
}

private struct DeferredPlaceholder<Placeholder: View>: View {
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var shown = false

    var body: some View {
        ZStack {
            if shown {
                placeholder()
            } else {
                Color.clear
            }
        }
        .task {
            do { try await Task.sleep(for: ContentActivityTiming.placeholderDelay) } catch {
                return
            }
            shown = true
        }
    }
}
