import SwiftUI

public enum ContentLoadingState: Equatable, Sendable {
    case loading
    case refreshing
    case partial
    case content
    case empty
    case error
    case offline
    case cancelled

    public var presentsContent: Bool {
        switch self {
        case .refreshing, .partial, .content: true
        case .loading, .empty, .error, .offline, .cancelled: false
        }
    }

    public var permitsRetry: Bool {
        switch self {
        case .empty, .error, .offline, .cancelled: true
        case .loading, .refreshing, .partial, .content: false
        }
    }
}

public struct LoadingContainer<Content: View, Placeholder: View>: View {
    public let state: ContentLoadingState
    public let title: String
    public let message: String
    public let retry: (() -> Void)?
    public let cancel: (() -> Void)?
    @ViewBuilder public let content: Content
    @ViewBuilder public let placeholder: Placeholder

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsLoading = false

    public init(
        state: ContentLoadingState,
        title: String = "No Content",
        message: String = "There is nothing to show yet.",
        retry: (() -> Void)? = nil,
        cancel: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.state = state
        self.title = title
        self.message = message
        self.retry = retry
        self.cancel = cancel
        self.content = content()
        self.placeholder = placeholder()
    }

    public var body: some View {
        ZStack {
            if state.presentsContent {
                content
            } else if state == .loading {
                placeholder
                    .opacity(showsLoading ? 1 : 0)
            } else {
                unavailable
            }
        }
        .animation(
            Motion.animation(Motion.feedback, reduceMotion: reduceMotion), value: state
        )
        .task(id: state) {
            showsLoading = false
            guard state == .loading else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            showsLoading = true
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label(unavailableTitle, systemImage: unavailableSymbol)
        } description: {
            Text(message)
        } actions: {
            HStack {
                if let retry, state.permitsRetry {
                    Button("Retry", action: retry)
                        .buttonStyle(EdithButtonStyle(.secondary))
                }
                if let cancel {
                    Button("Cancel", action: cancel)
                        .buttonStyle(EdithButtonStyle(.borderless))
                }
            }
        }
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

private struct SkeletonPhaseKey: EnvironmentKey {
    static let defaultValue = false
}

private extension EnvironmentValues {
    var skeletonPhase: Bool {
        get { self[SkeletonPhaseKey.self] }
        set { self[SkeletonPhaseKey.self] = newValue }
    }
}

public struct SkeletonGroup<Content: View>: View {
    @ViewBuilder public let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .environment(\.skeletonPhase, phase)
            .onAppear(perform: updatePhase)
            .onChange(of: reduceMotion) { _, _ in updatePhase() }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { phase = false }
            }
    }

    private func updatePhase() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { phase = false }
        guard !reduceMotion else { return }
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
            phase = true
        }
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
        SkeletonGroup {
            content.skeletonized()
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonPhase) private var phase

    func body(content: Content) -> some View {
        content
            .redacted(reason: .placeholder)
            .opacity(0.58)
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.16), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: phase ? proxy.size.width : -proxy.size.width * 0.45)
                    }
                    .mask {
                        content.redacted(reason: .placeholder)
                    }
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

public struct SkeletonBlock: View {
    public var width: Double?
    public var height: Double
    public var corner: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.skeletonPhase) private var phase

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
            .frame(width: scaledWidth, height: UIScale.pt(height))
            .overlay {
                if !reduceMotion {
                    GeometryReader { proxy in
                        LinearGradient(
                            colors: [.clear, Color.primary.opacity(0.08), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 0.45)
                        .offset(x: phase ? proxy.size.width : -proxy.size.width * 0.45)
                    }
                    .mask(RoundedRectangle(cornerRadius: UIScale.pt(corner)))
                }
            }
            .accessibilityHidden(true)
    }
}
