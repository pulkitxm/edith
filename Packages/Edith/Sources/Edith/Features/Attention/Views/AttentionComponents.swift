import AppKit
import EdithKit
import SwiftUI

enum AttentionPalette {
    static func accent(_ dark: Bool) -> Color { DashSkin.accent(dark) }

    static func level(_ level: AttentionProductivity, dark: Bool) -> Color {
        switch level {
        case .veryProductive: DashSkin.accent(dark)
        case .productive: DashSkin.accent(dark).opacity(0.55)
        case .neutral: DashSkin.lineStrong(dark)
        case .distracting: DashSkin.inkFaint(dark)
        case .veryDistracting: DashSkin.inkSoft(dark)
        }
    }

    static func category(_ category: AttentionCategory, dark: Bool) -> Color {
        category.isUnclassified ? DashSkin.grid(dark) : level(category.productivity, dark: dark)
    }

    static let levels = AttentionProductivity.ranked
}

enum AttentionFormat {
    static func duration(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(seconds)s"
    }

    static func clock(_ value: TimeInterval) -> String {
        let seconds = max(0, Int(value.rounded()))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    static func percent(_ value: Double, of total: Double) -> String {
        guard total > 0 else { return "0%" }
        return "\(Int((value / total * 100).rounded()))%"
    }

    static func delta(_ current: TimeInterval, _ previous: TimeInterval?) -> String? {
        guard let previous else { return nil }
        let change = current - previous
        guard abs(change) >= 60 else { return "same as before" }
        return "\(change > 0 ? "+" : "-")\(duration(abs(change))) vs before"
    }

    static func count(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

struct AttentionPanel<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    let trailing: Trailing
    let content: Content
    @Environment(\.colorScheme) private var scheme

    init(
        _ title: String, subtitle: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(10)) {
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(title)
                        .font(DashSkin.heading(16))
                        .foregroundStyle(DashSkin.ink(dark))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: UIScale.pt(8))
                trailing
            }
            content
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .edithSurface(cornerRadius: 16)
    }
}

struct AttentionTile: View {
    let label: String
    let value: String
    let detail: String?
    let tint: Color
    let symbol: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            HStack(spacing: UIScale.pt(6)) {
                Image(systemName: symbol)
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(DashSkin.mono(10)).tracking(UIScale.pt(1.2))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
            Text(value)
                .font(DashSkin.heading(24))
                .foregroundStyle(DashSkin.ink(dark))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            Text(detail ?? " ")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 14)
        .accessibilityElement(children: .combine)
    }
}

struct AttentionChip: View {
    let title: String
    let color: Color
    var active = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(5)) {
            Circle().fill(color).frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text(title)
                .font(.system(size: UIScale.pt(11), weight: active ? .semibold : .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
        }
        .padding(.horizontal, UIScale.pt(9))
        .padding(.vertical, UIScale.pt(4))
        .widgetBar(
            cornerRadius: 8,
            fill: active
                ? AnyShapeStyle(color.opacity(0.18)) : AnyShapeStyle(DashSkin.paper2(dark)),
            stroke: active ? color.opacity(0.6) : DashSkin.lineStrong(dark))
    }
}

struct AttentionCategoryBadge: View {
    let category: AttentionCategory
    var productivity: AttentionProductivity?
    var sphere: AttentionSphere?
    var source: AttentionCategorySource = .user
    var confidence: Double?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let level = productivity ?? category.productivity
        HStack(spacing: UIScale.pt(4)) {
            Circle()
                .fill(
                    category.isUnclassified
                        ? DashSkin.grid(dark) : AttentionPalette.level(level, dark: dark)
                )
                .frame(width: UIScale.pt(6), height: UIScale.pt(6))
            Text(category.name)
            if let sphere, sphere != .both {
                Text(sphere.title).foregroundStyle(DashSkin.inkFaint(dark))
            }
            if source == .jev {
                Text(confidence.map { "Jev \(Int(($0 * 100).rounded()))%" } ?? "Jev")
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .font(.system(size: UIScale.pt(10), weight: .semibold))
        .foregroundStyle(DashSkin.inkSoft(dark))
        .padding(.horizontal, UIScale.pt(6))
        .padding(.vertical, UIScale.pt(2))
        .background(DashSkin.grid(dark), in: Capsule())
        .help("\(category.name) · \(level.title) · \((sphere ?? category.sphere).title)")
    }
}

struct AttentionMixBar: View {
    let levels: [String: TimeInterval]
    let total: TimeInterval
    let scale: TimeInterval
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let parts = AttentionPalette.levels.compactMap {
            level -> (AttentionProductivity, TimeInterval)? in
            let value = levels[level.key] ?? 0
            return value > 0 ? (level, value) : nil
        }
        GeometryReader { geometry in
            let width = scale > 0 ? geometry.size.width * min(1, total / scale) : 0
            HStack(spacing: parts.count > 1 ? 2 : 0) {
                ForEach(parts, id: \.0) { part in
                    AttentionPalette.level(part.0, dark: dark)
                        .frame(
                            width: max(
                                2,
                                (width - CGFloat(parts.count - 1) * 2) * part.1 / max(total, 1)))
                }
            }
            .frame(width: width, alignment: .leading)
            .clipShape(Capsule())
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DashSkin.grid(dark), in: Capsule())
        }
        .frame(height: UIScale.pt(6))
        .accessibilityHidden(true)
    }
}

struct AttentionLegendRow: View {
    let color: Color
    let label: String
    let value: String
    var detail: String?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        HStack(spacing: UIScale.pt(8)) {
            RoundedRectangle(cornerRadius: 2).fill(color)
                .frame(width: UIScale.pt(9), height: UIScale.pt(9))
            Text(label)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            Spacer(minLength: UIScale.pt(6))
            if let detail {
                Text(detail)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Text(value)
                .font(.system(size: UIScale.pt(12), weight: .medium))
                .monospacedDigit()
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
    }
}

struct AttentionEmpty: View {
    let text: String
    var symbol = "tray"
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: UIScale.pt(8)) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(18)))
                .foregroundStyle(DashSkin.inkFaint(scheme == .dark))
            Text(text)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(scheme == .dark))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(22))
    }
}

struct AttentionNotice: View {
    let text: String
    let error: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: error ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).font(.system(size: UIScale.pt(11), weight: .medium))
            Spacer()
        }
        .foregroundStyle(error ? Color.red : Color.green)
        .padding(UIScale.pt(10))
        .background(
            (error ? Color.red : Color.green).opacity(0.1),
            in: RoundedRectangle(cornerRadius: 9))
    }
}

struct AttentionStatusPill: View {
    let title: String
    let state: String
    let good: Bool

    var body: some View {
        HStack(spacing: UIScale.pt(6)) {
            Circle().fill(good ? Color.green : Color.orange)
                .frame(width: UIScale.pt(7), height: UIScale.pt(7))
            Text("\(title): \(state)").font(.system(size: UIScale.pt(10), weight: .semibold))
        }
        .padding(.horizontal, UIScale.pt(9)).padding(.vertical, UIScale.pt(6))
        .background((good ? Color.green : Color.orange).opacity(0.1), in: Capsule())
    }
}

enum AttentionEventIconDescriptor: Equatable {
    case application(bundleID: String?)
    case website(URL?)
    case symbol(String)

    init(event: AttentionEvent) {
        switch event.source {
        case .application:
            self = .application(bundleID: event.bundleID)
        case .browser:
            self = .website(Self.remoteURL(event.faviconURL))
        case .media:
            self = .symbol(event.media?.kind == "audio" ? "music.note" : "play.rectangle")
        case .manual:
            self = .symbol("hand.tap")
        case .agent:
            self = .symbol("sparkles")
        }
    }

    init(entity: AttentionEntity) {
        if let faviconURL = Self.remoteURL(entity.faviconURL) {
            self = .website(faviconURL)
        } else if let bundleID = entity.bundleID, !bundleID.isEmpty {
            self = .application(bundleID: bundleID)
        } else {
            switch entity.source {
            case .application:
                self = .application(bundleID: nil)
            case .browser:
                self = .website(nil)
            case .media:
                self = .symbol("music.note")
            case .manual:
                self = .symbol("hand.tap")
            case .agent:
                self = .symbol("sparkles")
            }
        }
    }

    private static func remoteURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http"
        else { return nil }
        return url
    }
}

struct AttentionResolvedIcon: View {
    let descriptor: AttentionEventIconDescriptor
    let fallbackColor: Color
    var size: CGFloat = 26
    @State private var faviconImage: NSImage?
    @State private var applicationImage: NSImage?

    private var faviconURL: URL? {
        guard case .website(let url) = descriptor else { return nil }
        return url
    }

    private var applicationBundleID: String? {
        guard case .application(let bundleID) = descriptor else { return nil }
        return bundleID
    }

    var body: some View {
        Group {
            switch descriptor {
            case .application(let bundleID):
                if let icon = applicationImage
                    ?? AttentionApplicationIcon.cached(bundleID: bundleID)
                {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                } else {
                    fallback("macwindow")
                }
            case .website(let url):
                if url != nil, let faviconImage {
                    Image(nsImage: faviconImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(UIScale.pt(3))
                } else {
                    fallback("globe")
                }
            case .symbol(let systemName):
                fallback(systemName)
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .accessibilityHidden(true)
        .task(id: faviconURL) {
            faviconImage = nil
            guard let faviconURL,
                let data = try? await AgentFaviconClient().data(for: faviconURL),
                !Task.isCancelled
            else { return }
            faviconImage = NSImage(data: data)
        }
        .task(id: applicationBundleID) {
            applicationImage = nil
            guard let applicationBundleID,
                AttentionApplicationIcon.cached(bundleID: applicationBundleID) == nil
            else { return }
            let icon = await AttentionApplicationIcon.resolve(bundleID: applicationBundleID)
            guard !Task.isCancelled else { return }
            applicationImage = icon
        }
    }

    private func fallback(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: UIScale.pt(size * 0.62), weight: .medium))
            .foregroundStyle(fallbackColor)
    }
}

@MainActor
enum AttentionApplicationIcon {
    private static var cache: [String: NSImage] = [:]

    static func cached(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        return cache[bundleID]
    }

    static func resolve(bundleID: String?) async -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        if let cached = cache[bundleID] { return cached }
        let icon = await Task.detached { lookup(bundleID: bundleID) }.value
        if let icon { cache[bundleID] = icon }
        return icon
    }

    private nonisolated static func lookup(bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
    }
}

struct AttentionEntityIcon: View {
    let entity: AttentionEntity
    var size: CGFloat = 30
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            RoundedRectangle(cornerRadius: UIScale.pt(size * 0.24)).fill(DashSkin.grid(dark))
            AttentionResolvedIcon(
                descriptor: AttentionEventIconDescriptor(entity: entity),
                fallbackColor: DashSkin.inkSoft(dark), size: size * 0.72)
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
    }
}
