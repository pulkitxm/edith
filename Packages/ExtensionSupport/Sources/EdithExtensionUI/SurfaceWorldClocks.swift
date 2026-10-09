import EdithExtensionSupport
import SwiftUI

public struct SurfaceWorldClocks: View {
    @Environment(\.colorScheme) private var scheme
    private var dark: Bool { scheme == .dark }
    @Environment(\.compactLayout) private var compact
    private let tile: SurfaceTile
    @AppStorage private var zonesRaw: String
    @State private var now = Date()

    public init(tile: SurfaceTile, defaults: UserDefaults) {
        self.tile = tile
        _zonesRaw = AppStorage(
            wrappedValue: "America/New_York,America/Los_Angeles",
            AppStorageKeys.General.homeClockZones, store: defaults)
    }

    @State private var showAdd = false
    @State private var query = ""

    private var zoneIDs: [String] {
        SurfaceClockRules.zones(zonesRaw)
    }

    private var visibleZones: [String] {
        Array(zoneIDs.prefix(max(0, tile.itemLimit - 1)))
    }
    private var canAdd: Bool {
        zoneIDs.count < SurfaceClockRules.maxZones && tile.showActions
    }

    public var body: some View {
        Group {
            SurfaceFittedGrid(
                count: visibleZones.count + 1 + (canAdd ? 1 : 0),
                minimum: compact ? 76 : 104, gap: 16
            ) {
                ClockTile(
                    date: now, zone: TimeZone.current, label: "Local", dark: dark,
                    tile: tile, onRemove: nil)
                ForEach(visibleZones, id: \.self) { id in
                    ClockTile(
                        date: now, zone: TimeZone(identifier: id)!,
                        label: SurfaceClockRules.cityName(id), dark: dark, tile: tile,
                        onRemove: tile.showActions ? { remove(id) } : nil
                    )
                }
                if canAdd {
                    addButton
                }
            }
        }.accessibilityElement(children: .contain)
            .pageRefresh(interval: { .seconds(60) }) { now = Date() }
    }

    private func remove(_ id: String) {
        zonesRaw = zoneIDs.filter { $0 != id }.joined(separator: ",")
    }

    private func add(_ id: String) {
        guard zoneIDs.count < SurfaceClockRules.maxZones, !zoneIDs.contains(id),
            TimeZone(identifier: id) != nil
        else { return }
        zonesRaw = SurfaceClockRules.add(id, to: zonesRaw)
        showAdd = false
        query = ""
    }

    private var matches: [String] {
        SurfaceClockRules.zoneMatches(
            query: query, taken: Set(zoneIDs + [TimeZone.current.identifier]))
    }

    private var addButton: some View {
        Button {
            showAdd = true
        } label: {
            VStack(spacing: UIScale.pt(10)) {
                Circle()
                    .strokeBorder(
                        DashSkin.lineStrong(dark),
                        style: StrokeStyle(lineWidth: UIScale.pt(1), dash: [4, 3])
                    )
                    .frame(
                        width: UIScale.pt(compact ? 64 : 96), height: UIScale.pt(compact ? 64 : 96)
                    )
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: UIScale.pt(24), weight: .light))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                Text("Add city")
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .buttonStyle(.edith(.borderless))
        .help("Add a timezone clock")
        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                SearchField(placeholder: "Search city or region", text: $query)
                    .frame(width: UIScale.pt(240))
                ScrollView {
                    VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                        ForEach(matches, id: \.self) { id in
                            Button {
                                add(id)
                            } label: {
                                HStack {
                                    Text(SurfaceClockRules.cityName(id)).font(
                                        .system(size: UIScale.pt(12.5)))
                                    Spacer()
                                    Text(id.split(separator: "/").first.map(String.init) ?? "")
                                        .font(.system(size: UIScale.pt(10.5)))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, UIScale.pt(8))
                                .padding(.vertical, UIScale.pt(5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.edith(.borderless))
                        }
                        if matches.isEmpty {
                            Text("No matching timezones")
                                .font(.system(size: UIScale.pt(12)))
                                .foregroundStyle(.secondary)
                                .padding(UIScale.pt(8))
                        }
                    }
                }
                .frame(width: UIScale.pt(240), height: UIScale.pt(200))
            }
            .padding(UIScale.pt(12))
        }
    }
}

private struct ClockTile: View {
    let date: Date
    let zone: TimeZone
    let label: String
    let dark: Bool
    let tile: SurfaceTile
    let onRemove: (() -> Void)?
    @Environment(\.compactLayout) private var compact
    @State private var hovering = false

    private var faceSize: CGFloat { UIScale.pt(compact ? 64 : 96) }
    private var tileWidth: CGFloat { compact ? 76 : 104 }

    private var offsetLabel: String {
        SurfaceClockRules.offsetLabel(
            seconds: zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date))
    }

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            if tile.shows("faces") {
                ClockFace(zone: zone, dark: dark)
                    .frame(width: faceSize, height: faceSize)
                    .overlay(alignment: .topTrailing) {
                        if hovering, let onRemove {
                            Button(action: onRemove) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: UIScale.pt(16)))
                                    .foregroundStyle(DashSkin.inkFaint(dark))
                                    .background(Circle().fill(DashSkin.paper2(dark)))
                            }
                            .buttonStyle(.edith(.borderless))
                            .offset(x: 5, y: -5)
                            .help("Remove clock")
                        }
                    }
            }
            VStack(spacing: UIScale.pt(2)) {
                Text(label)
                    .font(DashSkin.heading(compact ? 13 : 15))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(date.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))
                    .font(DashSkin.mono(11.5))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                if tile.shows("offsets"),
                    tile.showDetails
                {
                    Text(offsetLabel).font(DashSkin.mono(9.5)).foregroundStyle(
                        DashSkin.inkFaint(dark))
                }
            }
        }
        .frame(minWidth: UIScale.pt(tileWidth), maxWidth: .infinity)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label), \(date.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))")
    }
}

private struct ClockFace: View {
    let zone: TimeZone
    let dark: Bool
    @State private var now = Date()

    var body: some View {
        face(now).pageRefresh(interval: { .seconds(1) }) { now = Date() }
    }

    private func face(_ date: Date) -> some View {
        Canvas { ctx, size in
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = zone
            let hour = Double(cal.component(.hour, from: date) % 12)
            let minute = Double(cal.component(.minute, from: date))
            let second = Double(cal.component(.second, from: date))
            let isDay = (6..<18).contains(cal.component(.hour, from: date))

            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1

            let face =
                isDay
                ? DashSkin.paper2(dark) : Color(white: dark ? 0.06 : 0.17)
            let mark = isDay ? DashSkin.inkFaint(dark) : Color.gray
            let hand = isDay ? DashSkin.ink(dark) : Color(white: 0.94)

            let dial = Path(
                ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
            ctx.fill(dial, with: .color(face))
            ctx.stroke(dial, with: .color(DashSkin.lineStrong(dark)), lineWidth: UIScale.pt(1))

            for i in 0..<12 {
                let angle = Double(i) / 12 * 2 * .pi
                let long = i % 3 == 0
                let outer = point(center, radius - 3, angle)
                let inner = point(center, radius - (long ? 9 : 6), angle)
                var tick = Path()
                tick.move(to: inner)
                tick.addLine(to: outer)
                ctx.stroke(
                    tick, with: .color(mark),
                    style: StrokeStyle(
                        lineWidth: long ? 1.6 : 1, lineCap: .round))
            }

            let hourAngle = (hour + minute / 60) / 12 * 2 * .pi
            let minuteAngle = (minute + second / 60) / 60 * 2 * .pi
            let secondAngle = second / 60 * 2 * .pi
            drawHand(
                &ctx, center, length: radius * 0.48, angle: hourAngle, width: UIScale.pt(2.4),
                color: hand)
            drawHand(
                &ctx, center, length: radius * 0.72, angle: minuteAngle, width: UIScale.pt(1.7),
                color: hand)
            drawHand(
                &ctx, center, length: radius * 0.8, angle: secondAngle, width: UIScale.pt(1),
                color: DashSkin.accent(dark))
            ctx.fill(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - 2, y: center.y - 2, width: UIScale.pt(4),
                        height: UIScale.pt(4))),
                with: .color(DashSkin.accent(dark)))
        }
    }

    private func point(_ center: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(
            x: center.x + radius * CGFloat(sin(angle)),
            y: center.y - radius * CGFloat(cos(angle)))
    }

    private func drawHand(
        _ ctx: inout GraphicsContext, _ center: CGPoint, length: CGFloat, angle: Double,
        width: CGFloat, color: Color
    ) {
        var path = Path()
        path.move(to: point(center, -length * 0.15, angle))
        path.addLine(to: point(center, length, angle))
        ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }
}
