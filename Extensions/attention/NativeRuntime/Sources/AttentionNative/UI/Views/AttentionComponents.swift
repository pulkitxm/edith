internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import AppKit
import ImageIO
import SwiftUI

enum AttentionPalette {
    static func accent(_ dark: Bool) -> Color { DashSkin.accent(dark) }

    static func level(_ level: AttentionProductivity, dark: Bool) -> Color {
        switch level {
        case .veryProductive: Color(red: 0.20, green: 0.72, blue: 0.59)
        case .productive: Color(red: 0.32, green: 0.66, blue: 0.78)
        case .neutral: DashSkin.lineStrong(dark)
        case .distracting: Color(red: 0.90, green: 0.62, blue: 0.30)
        case .veryDistracting: Color(red: 0.89, green: 0.39, blue: 0.39)
        }
    }

    static func category(_ category: AttentionCategory, dark: Bool) -> Color {
        category.isUnclassified ? DashSkin.grid(dark) : level(category.productivity, dark: dark)
    }

    static let levels = AttentionProductivity.ranked
}

enum AttentionFormat {
    static func duration(_ value: TimeInterval) -> String {
        CompactDuration.detailed(value.rounded(), showsSeconds: false)
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
        PagePanel {
            PageSectionHeader(title, subtitle: subtitle) { trailing }
        } content: {
            content
        }
    }
}

enum AttentionTileGrid {
    static func columns(_ compact: Bool, regular: Int = 4) -> [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(), spacing: UIScale.pt(PageMetrics.cardSpacing), alignment: .top),
            count: compact ? 2 : regular)
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
        PageMetric(title: label, value: value, detail: detail ?? " ", symbol: symbol, tint: tint)
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
        .font(.edithText(.caption).weight(.semibold))
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
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
            Spacer(minLength: UIScale.pt(6))
            if let detail {
                Text(detail)
                    .font(.edithText(.subheadline))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Text(value)
                .font(.edithText(.callout).weight(.medium))
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
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.inkSoft(scheme == .dark))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, UIScale.pt(22))
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
            Text("\(title): \(state)").font(.edithText(.caption).weight(.semibold))
        }
        .padding(.horizontal, UIScale.pt(9)).padding(.vertical, UIScale.pt(6))
        .background((good ? Color.green : Color.orange).opacity(0.1), in: Capsule())
    }
}

enum AttentionEventIconDescriptor: Hashable {
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
    @State private var loaded: AttentionLoadedIcon?
    @Environment(\.attentionUIClient) private var uiClient

    var body: some View {
        let image =
            loaded?.descriptor == descriptor
            ? loaded?.image : AttentionIconStore.shared.cached(descriptor)
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(descriptor.isWebsite ? UIScale.pt(3) : 0)
            } else {
                Image(systemName: descriptor.fallbackSymbol)
                    .font(.system(size: UIScale.pt(size * 0.62), weight: .medium))
                    .foregroundStyle(fallbackColor)
            }
        }
        .frame(width: UIScale.pt(size), height: UIScale.pt(size))
        .accessibilityHidden(true)
        .pageTask(id: descriptor) {
            let store = AttentionIconStore.shared
            guard store.needsLoad(descriptor) else { return }
            let image = await store.load(descriptor, client: uiClient)
            guard !Task.isCancelled, let image else { return }
            loaded = AttentionLoadedIcon(descriptor: descriptor, image: image)
        }
    }
}

struct AttentionLoadedIcon {
    let descriptor: AttentionEventIconDescriptor
    let image: NSImage
}

extension AttentionEventIconDescriptor {
    var isWebsite: Bool {
        if case .website = self { return true }
        return false
    }

    var fallbackSymbol: String {
        switch self {
        case .application: "macwindow"
        case .website: "globe"
        case .symbol(let name): name
        }
    }
}

@MainActor
final class AttentionIconStore {
    static let shared = AttentionIconStore()
    nonisolated static let pixelSize = 64

    private let images = NSCache<NSString, NSImage>()
    private var pending: [AttentionEventIconDescriptor: Task<NSImage?, Never>] = [:]
    private var missing: Set<AttentionEventIconDescriptor> = []

    init(limit: Int = 600) {
        images.countLimit = limit
    }

    func cached(_ descriptor: AttentionEventIconDescriptor) -> NSImage? {
        guard let key = Self.key(descriptor) else { return nil }
        return images.object(forKey: key)
    }

    func needsLoad(_ descriptor: AttentionEventIconDescriptor) -> Bool {
        guard Self.key(descriptor) != nil else { return false }
        return cached(descriptor) == nil && !missing.contains(descriptor)
    }

    func load(
        _ descriptor: AttentionEventIconDescriptor,
        fetch: @escaping @MainActor () async -> Data?
    ) async -> NSImage? {
        guard let key = Self.key(descriptor) else { return nil }
        if let image = images.object(forKey: key) { return image }
        guard !missing.contains(descriptor) else { return nil }
        if let task = pending[descriptor] { return await task.value }
        let task = Task { @MainActor in
            guard let data = await fetch() else { return nil as NSImage? }
            return await Task.detached(priority: .utility) {
                AttentionIconStore.thumbnail(data, pixels: AttentionIconStore.pixelSize)
            }.value
        }
        pending[descriptor] = task
        let image = await task.value
        pending[descriptor] = nil
        if let image {
            images.setObject(image, forKey: key)
        } else if !Task.isCancelled {
            missing.insert(descriptor)
        }
        return image
    }

    func load(_ descriptor: AttentionEventIconDescriptor, client: AttentionUIClient?) async
        -> NSImage?
    {
        await load(descriptor) {
            switch descriptor {
            case .application(let bundleID?):
                if let client {
                    let bytes = try? await client.invoke(
                        "attention.ui.application.icon",
                        payload: AttentionPayload.encode(bundleID))
                    return bytes.flatMap { try? AttentionPayload.decode(Data?.self, from: $0) }
                }
                return await AttentionApplicationIcon.png(bundleID: bundleID)
            case .website(let url?):
                if let client {
                    let bytes = try? await client.invoke(
                        AgentFaviconClient.operation, payload: AttentionPayload.encode(url))
                    return bytes.flatMap { try? AttentionPayload.decode(Data?.self, from: $0) }
                }
                return try? await AgentFaviconClient().data(for: url)
            default:
                return nil
            }
        }
    }

    private static func key(_ descriptor: AttentionEventIconDescriptor) -> NSString? {
        switch descriptor {
        case .application(let bundleID?) where !bundleID.isEmpty: "app:\(bundleID)" as NSString
        case .website(let url?): "web:\(url.absoluteString)" as NSString
        default: nil
        }
    }

    nonisolated static func thumbnail(_ data: Data, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                ] as CFDictionary)
        else { return NSImage(data: data) }
        return NSImage(
            cgImage: image, size: NSSize(width: image.width / 2, height: image.height / 2))
    }
}

enum AttentionApplicationIcon {
    static func png(bundleID: String, pixels: Int = AttentionIconStore.pixelSize) async -> Data? {
        guard !bundleID.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            guard let icon = lookup(bundleID: bundleID) else { return nil as Data? }
            return render(icon, pixels: pixels)
        }.value
    }

    private static func lookup(bundleID: String) -> NSImage? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.icon
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map {
                NSWorkspace.shared.icon(forFile: $0.path)
            }
    }

    static func render(_ icon: NSImage, pixels: Int) -> Data? {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero,
            operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
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
