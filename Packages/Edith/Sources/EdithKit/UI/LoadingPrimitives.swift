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

public struct LoadingContainer<Content: View, Placeholder: View>: View {
    public let state: ContentLoadingState
    public let title: String
    public let message: String
    public let retry: (() -> Void)?
    public let cancel: (() -> Void)?
    public let refreshing: Bool
    private let content: () -> Content
    private let placeholder: () -> Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        state: ContentLoadingState,
        title: String = "No Content",
        message: String = "There is nothing to show yet.",
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        refreshing: Bool = false,
        @ViewBuilder content: @escaping () -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.state = state
        self.title = title
        self.message = message
        self.retry = retry
        self.cancel = cancel
        self.refreshing = refreshing
        self.content = content
        self.placeholder = placeholder
    }

    public var body: some View {
        ZStack {
            if state.presentsContent {
                content()
                    .overlay(alignment: .topTrailing) {
                        if refreshing {
                            LoadingIndicator("Refreshing")
                                .padding(8)
                                .background(.regularMaterial, in: Capsule())
                                .allowsHitTesting(false)
                        }
                    }
            } else if state == .loading {
                SkeletonGroup { placeholder() }
            } else {
                unavailable
            }
        }
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state
        )
    }

    private var unavailable: some View {
        ContentStatusView(
            unavailableTitle, message: message, symbol: unavailableSymbol,
            actionTitle: "Retry", action: state.permitsRetry ? retry : nil,
            secondaryTitle: "Cancel", secondaryAction: cancel)
    }

    private var unavailableTitle: String {
        switch state {
        case .offline: "Offline"
        case .error: "Couldn’t Load Content"
        case .cancelled: "Loading Cancelled"
        default: title
        }
    }

    private var unavailableSymbol: String {
        switch state {
        case .offline: "wifi.slash"
        case .error: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        default: "tray"
        }
    }
}

public struct ContentStatusView: View {
    public let title: String
    public let message: String
    public let symbol: String
    public let actionTitle: String
    public let action: (() -> Void)?
    public let secondaryTitle: String
    public let secondaryAction: (() -> Void)?

    public init(
        _ title: String, message: String, symbol: String = "tray",
        actionTitle: String = "Retry", action: (() -> Void)? = nil,
        secondaryTitle: String = "Cancel", secondaryAction: (() -> Void)? = nil
    ) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.actionTitle = actionTitle
        self.action = action
        self.secondaryTitle = secondaryTitle
        self.secondaryAction = secondaryAction
    }

    public var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(32), weight: .light))
                .foregroundStyle(.secondary)
            Text(title).font(.edithText(.title2)).fontWeight(.semibold)
            Text(message)
                .font(.edithText(.body))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(8)) { actions }
                VStack(spacing: UIScale.pt(8)) { actions }
            }.fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(24))
        .frame(maxWidth: .infinity, minHeight: UIScale.pt(220))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var actions: some View {
        if let action {
            Button(actionTitle, action: action).buttonStyle(.edith(.secondary))
        }
        if let secondaryAction {
            Button(secondaryTitle, action: secondaryAction).buttonStyle(.edith(.borderless))
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
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

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
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store)
    private var themeName = "accent"

    public init(value: Double, total: Double = 1) {
        self.value = value
        self.total = total
    }

    public var body: some View {
        ProgressView(value: fraction)
            .tint(themeColor(themeName))
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
        RoundedRectangle(cornerRadius: UIScale.pt(corner))
            .fill(Color.primary.opacity(0.07))
            .frame(maxWidth: scaledWidth)
            .frame(height: UIScale.pt(height))
            .overlay {
                LoadingShimmer()
                    .mask(RoundedRectangle(cornerRadius: UIScale.pt(corner)))
            }
            .accessibilityHidden(true)
    }
}
