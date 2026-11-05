import SwiftUI

public struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    public init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: .center, spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                if let subtitle {
                    Text(subtitle).settingsSubtitle()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: UIScale.pt(PageMetrics.controlSpacing))
            trailing()
        }
    }
}

public struct SettingsNoticeRow: View {
    let title: String
    let message: String
    var symbol = "info.circle.fill"
    var tint: Color?

    public init(
        _ title: String, message: String, symbol: String = "info.circle.fill", tint: Color? = nil
    ) {
        self.title = title
        self.message = message
        self.symbol = symbol
        self.tint = tint
    }

    public var body: some View {
        LabeledContent {
            EmptyView()
        } label: {
            Text("\(Text(Image(systemName: symbol)).foregroundColor(tint ?? .secondary)) \(title)")
            Text(message)
        }
    }
}

public struct SettingsErrorRow: View {
    let title: String
    let message: String
    var retryTitle = "Try Again"
    let retry: () -> Void

    public init(
        _ title: String, message: String, retryTitle: String = "Try Again",
        retry: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        LabeledContent {
            Button(retryTitle, action: retry).buttonStyle(.edith(.secondary))
        } label: {
            Text(
                "\(Text(Image(systemName: "exclamationmark.triangle.fill")).foregroundColor(.orange)) \(title)"
            )
            Text(message)
        }
    }
}

public struct SettingsShortcutRow: View {
    let keyPrefix: String
    let defaultLabel: String
    let purpose: String
    var title = "Keyboard shortcut"

    public init(
        keyPrefix: String, defaultLabel: String, purpose: String,
        title: String = "Keyboard shortcut"
    ) {
        self.keyPrefix = keyPrefix
        self.defaultLabel = defaultLabel
        self.purpose = purpose
        self.title = title
    }

    public var body: some View {
        SettingsRow(
            title, subtitle: purpose + " Click the shortcut, then press new keys to change it."
        ) {
            HotKeyRecorderControl(keyPrefix: keyPrefix, defaultLabel: defaultLabel)
        }
    }
}

public struct SettingsSliderRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let readout: String

    public init(
        _ title: String, subtitle: String? = nil, value: Binding<Double>,
        in range: ClosedRange<Double>, step: Double? = nil, readout: String
    ) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
        self.step = step
        self.readout = readout
    }

    public var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            HStack(spacing: UIScale.pt(12)) {
                slider
                    .labelsHidden()
                    .frame(width: UIScale.pt(PageMetrics.settingsSliderWidth))
                Text(readout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(
                        width: UIScale.pt(PageMetrics.settingsReadoutWidth), alignment: .trailing)
            }
        }
    }

    @ViewBuilder private var slider: some View {
        if let step {
            Slider(value: $value, in: range, step: step) { Text(title) }
        } else {
            Slider(value: $value, in: range) { Text(title) }
        }
    }
}

public struct SettingsStepperRow: View {
    let title: String
    var subtitle: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit: String?

    public init(
        _ title: String, subtitle: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>,
        step: Int = 1, unit: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        _value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(range.upperBound, max(range.lowerBound, $0)) })
    }

    public var body: some View {
        SettingsRow(title, subtitle: subtitle) {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                EdithNumberField(
                    value: clamped, width: UIScale.pt(PageMetrics.settingsNumberWidth),
                    grouped: false)
                if let unit { Text(unit).foregroundStyle(.secondary).lineLimit(1) }
                Stepper(title, value: clamped, in: range, step: step).labelsHidden()
            }
        }
    }
}

@MainActor
public protocol ControlSettingsPresenting: AnyObject {
    var load: ContentLoad { get }
    var error: String? { get }
    var ready: Bool { get }
    var active: Bool { get }
    var running: Bool { get }
    func changed()
    func refresh() async
    func retry()
}

extension ControlSettingsPresenting {
    public func retry() {
        changed()
        Task { await refresh() }
    }
}

public struct SettingsIssue: Sendable {
    public let message: String
    public let retry: @MainActor @Sendable () -> Void

    public init(message: String, retry: @escaping @MainActor @Sendable () -> Void) {
        self.message = message
        self.retry = retry
    }
}

private struct SettingsIssueKey: EnvironmentKey {
    static let defaultValue: SettingsIssue? = nil
}

extension EnvironmentValues {
    public var settingsIssue: SettingsIssue? {
        get { self[SettingsIssueKey.self] }
        set { self[SettingsIssueKey.self] = newValue }
    }
}

public struct SettingsIssueSection: View {
    @Environment(\.settingsIssue) private var issue

    public init() {}

    public var body: some View {
        if let issue {
            Section {
                SettingsErrorRow(
                    "Couldn’t sync these settings",
                    message: "\(issue.message) Your last saved settings are shown.",
                    retryTitle: "Retry", retry: { issue.retry() })
            }
        }
    }
}

public struct ControlSettingsHost<Presentation: ControlSettingsPresenting, Content: View>: View {
    let presentation: Presentation
    @ViewBuilder let content: () -> Content

    public init(presentation: Presentation, @ViewBuilder content: @escaping () -> Content) {
        self.presentation = presentation
        self.content = content
    }

    public var body: some View {
        let presentation = presentation
        PageLoading(
            state: presentation.load.state, title: "Settings unavailable",
            message: presentation.error ?? "The extension engine is unavailable.",
            layout: .form, retry: { presentation.retry() }
        ) {
            content()
        }
        .padding(
            presentation.load.state == .loading ? UIScale.pt(PageMetrics.groupedFormInset) : 0
        )
        .environment(
            \.settingsIssue,
            presentation.ready
                ? presentation.error.map { message in
                    SettingsIssue(message: message) { [presentation] in presentation.retry() }
                } : nil
        )
        .pageRefresh(
            active: presentation.active && presentation.running,
            interval: { .seconds(2) }, cancel: { presentation.load.cancel() }
        ) {
            await presentation.refresh()
        }
    }
}
