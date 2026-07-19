import AppKit
import Charts
import EdithKit
import EventKit
import SwiftUI

struct HomePage: View {
    @ObservedObject private var model = DashboardModel.shared
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var usageEnabled = false
    @AppStorage("tabMusicEnabled", store: SharedDefaults.store) private var musicEnabled = false
    @AppStorage("tabCalendarEnabled", store: SharedDefaults.store) private var calendarEnabled =
        false
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = false
    @AppStorage("presenterEnabled", store: SharedDefaults.store) private var presenterEnabled =
        false
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var blurMoney: Bool { presenterState.active && presenterBlurMoney }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 640
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HomeHeader(dark: dark)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            WorldClocksCard(dark: dark)
                            if systemEnabled || presenterEnabled { QuickActionsCard(dark: dark) }
                        }
                        VStack(spacing: 16) {
                            WorldClocksCard(dark: dark)
                            if systemEnabled || presenterEnabled { QuickActionsCard(dark: dark) }
                        }
                    }
                    if usageEnabled, model.loaded {
                        SkinCard(title: "Activity", note: "daily cost", dark: dark) {
                            ActivityHeatmap(
                                days: model.calendarDays, cuts: model.chartData.heatCuts,
                                model: model, dark: dark, blur: blurMoney)
                        }
                    }
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: compact ? 260 : 340), spacing: 16)],
                        alignment: .leading, spacing: 16
                    ) {
                        Group {
                            if calendarEnabled { MeetingsCard(dark: dark) }
                            if usageEnabled {
                                UsageSummaryCard(dark: dark)
                                LimitsSummaryCard(dark: dark)
                            }
                            if musicEnabled { MusicCard(dark: dark) }
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                }
                .padding(.horizontal, compact ? 18 : 24)
                .padding(.top, 18)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(background)
            .environment(\.compactLayout, compact)
        }
        .navigationTitle("Home")
        .task(id: usageEnabled) {
            if usageEnabled { await model.load() }
        }
    }

    private var background: some View {
        DashSkin.paper(dark)
            .overlay(alignment: .topTrailing) {
                RadialGradient(
                    colors: [DashSkin.accent(dark).opacity(0.08), .clear], center: .topTrailing,
                    startRadius: 0, endRadius: 620
                )
                .ignoresSafeArea(edges: .vertical)
            }
            .overlay(alignment: .bottomLeading) {
                RadialGradient(
                    colors: [DashPalette.slate(dark).opacity(0.06), .clear],
                    center: .bottomLeading, startRadius: 0, endRadius: 520
                )
                .ignoresSafeArea(edges: .vertical)
            }
            .ignoresSafeArea(edges: .vertical)
    }
}

enum HomeMath {
    static let maxZones = 2

    static let zoneSuggestions = [
        "Europe/London", "Europe/Berlin", "Asia/Kolkata", "Asia/Tokyo", "Asia/Singapore",
        "Australia/Sydney", "America/Chicago", "America/Sao_Paulo", "Asia/Dubai",
    ]

    static func salutation(hour: Int) -> String {
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        case 17..<22: return "Good evening"
        default: return "Up late"
        }
    }

    static func clockLabel(hour24: Int, minute: Int, second: Int) -> String {
        let h = hour24 % 12 == 0 ? 12 : hour24 % 12
        return String(format: "%d:%02d:%02d", h, minute, second)
    }

    static func cityName(_ id: String) -> String {
        (id.split(separator: "/").last.map(String.init) ?? id)
            .replacingOccurrences(of: "_", with: " ")
    }

    static func offsetLabel(seconds: Int) -> String {
        if seconds == 0 { return "same time" }
        let hours = Double(seconds) / 3600
        return hours == hours.rounded()
            ? String(format: "%+.0fh", hours) : String(format: "%+.1fh", hours)
    }

    static func topModels(days: [HeatDay?], limit: Int = 3) -> [NamedValue] {
        var totals: [String: Double] = [:]
        for day in days {
            for entry in day?.models ?? [] {
                totals[entry.name, default: 0] += entry.value
            }
        }
        return totals.sorted { $0.value > $1.value }.prefix(limit).map {
            NamedValue(id: $0.key, name: $0.key, value: $0.value)
        }
    }

    static func zoneMatches(query: String, taken: Set<String>) -> [String] {
        if query.isEmpty {
            return zoneSuggestions.filter { !taken.contains($0) }
        }
        let needle = query.replacingOccurrences(of: " ", with: "_")
        return Set(TimeZone.knownTimeZoneIdentifiers).union(zoneSuggestions)
            .sorted()
            .filter { !taken.contains($0) && $0.localizedCaseInsensitiveContains(needle) }
            .prefix(14).map { $0 }
    }
}

private struct HomeHeader: View {
    let dark: Bool
    @Environment(\.compactLayout) private var compact
    @ObservedObject private var visibility = WindowVisibility.shared

    private var titleSize: CGFloat { compact ? 28 : 40 }

    private var firstName: String {
        let licensed = SharedDefaults.store.string(forKey: LicenseState.nameKey) ?? ""
        let full = licensed.isEmpty ? NSFullUserName() : licensed
        let name = full.isEmpty ? NSUserName() : full
        return name.split(separator: " ").first.map(String.init) ?? name
    }

    private func clockString(_ now: Date) -> String {
        let cal = Calendar.current
        return HomeMath.clockLabel(
            hour24: cal.component(.hour, from: now),
            minute: cal.component(.minute, from: now),
            second: cal.component(.second, from: now))
    }

    private func salutation(_ date: Date) -> String {
        HomeMath.salutation(hour: Calendar.current.component(.hour, from: date))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    greeting(now)
                    clockBlock(now, alignment: .leading)
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    greeting(now)
                    Spacer(minLength: 16)
                    clockBlock(now, alignment: .trailing)
                }
            }
        }
    }

    private func greeting(_ now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            (Text("\(salutation(now)), ")
                + Text(firstName).italic().foregroundColor(DashSkin.accentDeep(dark))
                + Text("."))
                .font(DashSkin.serif(titleSize))
                .foregroundStyle(DashSkin.ink(dark))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(
                now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
                    .uppercased()
            )
            .font(DashSkin.mono(11)).tracking(1.6)
            .foregroundStyle(DashSkin.inkFaint(dark))
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func clockText(_ date: Date) -> some View {
        Text(clockString(date))
            .font(DashSkin.serif(titleSize))
            .foregroundStyle(DashSkin.ink(dark))
            .monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.6)
    }

    private func clockBlock(_ now: Date, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            if visibility.visible {
                TimelineView(.periodic(from: .now, by: 1)) { tick in
                    clockText(tick.date)
                }
            } else {
                clockText(now)
            }
            Text(
                "\(Calendar.current.component(.hour, from: now) < 12 ? "AM" : "PM")"
                    + " · \(TimeZone.current.abbreviation() ?? "local")"
            )
            .font(DashSkin.mono(11)).tracking(1.2)
            .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }
}

private struct WorldClocksCard: View {
    let dark: Bool
    @Environment(\.compactLayout) private var compact
    @AppStorage("homeClockZones", store: SharedDefaults.store) private var zonesRaw =
        "America/New_York,America/Los_Angeles"
    @State private var showAdd = false
    @State private var query = ""

    private var zoneIDs: [String] {
        zonesRaw.split(separator: ",").map(String.init).filter { TimeZone(identifier: $0) != nil }
    }

    var body: some View {
        SkinCard(title: "World clocks", note: "hover a clock to remove", dark: dark) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                WrapHStack(spacing: 20, lineSpacing: 16) {
                    ClockTile(
                        date: context.date, zone: TimeZone.current, label: "Local", dark: dark,
                        onRemove: nil)
                    ForEach(zoneIDs, id: \.self) { id in
                        ClockTile(
                            date: context.date, zone: TimeZone(identifier: id)!,
                            label: HomeMath.cityName(id), dark: dark
                        ) {
                            remove(id)
                        }
                    }
                    if zoneIDs.count < HomeMath.maxZones {
                        addButton
                    }
                }
            }
        }
    }

    private func remove(_ id: String) {
        zonesRaw = zoneIDs.filter { $0 != id }.joined(separator: ",")
    }

    private func add(_ id: String) {
        guard zoneIDs.count < HomeMath.maxZones, !zoneIDs.contains(id),
            TimeZone(identifier: id) != nil
        else { return }
        zonesRaw = (zoneIDs + [id]).joined(separator: ",")
        showAdd = false
        query = ""
    }

    private var matches: [String] {
        HomeMath.zoneMatches(
            query: query, taken: Set(zoneIDs + [TimeZone.current.identifier]))
    }

    private var addButton: some View {
        Button {
            showAdd = true
        } label: {
            VStack(spacing: 10) {
                Circle()
                    .strokeBorder(
                        DashSkin.lineStrong(dark), style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                    .frame(width: compact ? 64 : 96, height: compact ? 64 : 96)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                Text("Add city")
                    .font(.system(size: 12))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Add a timezone clock")
        .popover(isPresented: $showAdd, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search city or region", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches, id: \.self) { id in
                            Button {
                                add(id)
                            } label: {
                                HStack {
                                    Text(HomeMath.cityName(id)).font(.system(size: 12.5))
                                    Spacer()
                                    Text(id.split(separator: "/").first.map(String.init) ?? "")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .pointerCursor()
                        }
                        if matches.isEmpty {
                            Text("No matching timezones")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .padding(8)
                        }
                    }
                }
                .frame(width: 240, height: 200)
            }
            .padding(12)
        }
    }
}

private struct ClockTile: View {
    let date: Date
    let zone: TimeZone
    let label: String
    let dark: Bool
    let onRemove: (() -> Void)?
    @Environment(\.compactLayout) private var compact
    @State private var hovering = false

    private var faceSize: CGFloat { compact ? 64 : 96 }
    private var tileWidth: CGFloat { compact ? 92 : 112 }

    private var offsetLabel: String {
        HomeMath.offsetLabel(
            seconds: zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date))
    }

    var body: some View {
        VStack(spacing: 10) {
            ClockFace(zone: zone, dark: dark)
                .frame(width: faceSize, height: faceSize)
                .overlay(alignment: .topTrailing) {
                    if hovering, let onRemove {
                        Button(action: onRemove) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(DashSkin.inkFaint(dark))
                                .background(Circle().fill(DashSkin.paper2(dark)))
                        }
                        .buttonStyle(.plain)
                        .pointerCursor()
                        .offset(x: 5, y: -5)
                        .help("Remove clock")
                    }
                }
            VStack(spacing: 2) {
                Text(label)
                    .font(DashSkin.serif(compact ? 13 : 15))
                    .foregroundStyle(DashSkin.ink(dark))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(date.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))
                    .font(DashSkin.mono(11.5))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Text(offsetLabel)
                    .font(DashSkin.mono(9.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .frame(width: tileWidth)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(label), \(date.formatted(Date.FormatStyle(timeZone: zone).hour().minute()))")
    }
}

private struct ClockFace: View {
    let zone: TimeZone
    let dark: Bool
    @ObservedObject private var visibility = WindowVisibility.shared

    var body: some View {
        if visibility.visible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                face(context.date)
            }
        } else {
            face(Date())
        }
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
                ? DashSkin.paper2(dark) : DashPalette.color(dark ? "#12100d" : "#2e2822")
            let mark = isDay ? DashSkin.inkFaint(dark) : DashPalette.color("#8a7d6c")
            let hand = isDay ? DashSkin.ink(dark) : DashPalette.color("#f1e9dc")

            let dial = Path(
                ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2))
            ctx.fill(dial, with: .color(face))
            ctx.stroke(dial, with: .color(DashSkin.lineStrong(dark)), lineWidth: 1)

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
            drawHand(&ctx, center, length: radius * 0.48, angle: hourAngle, width: 2.4, color: hand)
            drawHand(
                &ctx, center, length: radius * 0.72, angle: minuteAngle, width: 1.7, color: hand)
            drawHand(
                &ctx, center, length: radius * 0.8, angle: secondAngle, width: 1,
                color: DashSkin.accent(dark))
            ctx.fill(
                Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)),
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

private struct QuickActionsCard: View {
    let dark: Bool
    @AppStorage("preventSleep", store: SharedDefaults.store) private var preventSleep = false
    @AppStorage("presenterMode", store: SharedDefaults.store) private var presenterMode = false
    @AppStorage("presenterEnabled", store: SharedDefaults.store) private var presenterEnabled =
        false
    @AppStorage("tabSystemEnabled", store: SharedDefaults.store) private var systemEnabled = false
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        SkinCard(title: "Quick actions", dark: dark) {
            HStack(alignment: .top, spacing: 12) {
                if systemEnabled {
                    tile(
                        icon: "keyboard", title: "Clean keys",
                        sub: "Lock the keyboard to wipe it", active: false
                    ) {
                        IPC.post(IPC.Name.requestKeyboardClean)
                    }
                    tile(
                        icon: preventSleep ? "moon.zzz.fill" : "moon.zzz", title: "Keep awake",
                        sub: "Stop this Mac from sleeping", active: preventSleep
                    ) {
                        preventSleep.toggle()
                    }
                }
                if presenterEnabled {
                    tile(
                        icon: "person.wave.2", title: "Presenter mode",
                        sub: "Blur sensitive values on screen", active: presenterMode
                    ) {
                        presenterMode.toggle()
                        if !presenterMode { IPC.post(IPC.Name.presenterPauseAuto) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func tile(
        icon: String, title: String, sub: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .frame(height: 26)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(sub)
                    .font(.system(size: 10.5))
                    .foregroundStyle(active ? .white.opacity(0.8) : DashSkin.inkFaint(dark))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(DashSkin.ink(dark)))
            .background(
                active ? AnyShapeStyle(theme) : AnyShapeStyle(.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(sub)
    }
}

private struct MeetingsCard: View {
    let dark: Bool
    @StateObject private var store = CalendarStore()
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurCalendar", store: SharedDefaults.store)
    private var presenterBlurCalendar = true

    private var theme: Color { themeColor(themeName) }
    private var blurCalendar: Bool { presenterState.active && presenterBlurCalendar }

    private var todayEvents: [EKEvent] {
        store.events.filter { Calendar.current.isDateInToday($0.startDate) }
    }

    var body: some View {
        SkinCard(title: "Today's meetings", note: note, dark: dark) {
            VStack(alignment: .leading, spacing: 0) {
                if store.authStatus != .fullAccess {
                    accessPrompt
                } else if todayEvents.isEmpty {
                    Text("No meetings today. Clear runway.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    ForEach(todayEvents.prefix(6), id: \.eventIdentifier) { event in
                        row(event)
                        if event != todayEvents.prefix(6).last {
                            Divider().opacity(0.4)
                        }
                    }
                }
                jumpLink("Open Calendar", to: .calendar, dark: dark)
            }
        }
        .onAppear { store.refreshAuthStatus() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            store.refreshAuthStatus()
        }
    }

    private var note: String {
        guard store.authStatus == .fullAccess else { return "" }
        let count = todayEvents.count
        return count == 0 ? "" : "\(count) event\(count == 1 ? "" : "s")"
    }

    private func row(_ event: EKEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(timeLabel(event))
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(event.title ?? "Untitled")
                .font(.system(size: 12.5))
                .lineLimit(1)
                .foregroundStyle(DashSkin.ink(dark))
                .frame(maxWidth: .infinity, alignment: .leading)
                .presenterBlur(blurCalendar)
            if let url = MeetingLink.url(for: event) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme)
                }
                .buttonStyle(HoverButtonStyle())
                .help("Join meeting")
            }
        }
        .padding(.vertical, 6)
    }

    private func timeLabel(_ event: EKEvent) -> String {
        guard !event.isAllDay else { return "All day" }
        let start = event.startDate.formatted(date: .omitted, time: .shortened)
        let end = event.endDate.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }

    private var accessPrompt: some View {
        HStack(spacing: 8) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(.orange)
            Text("Grant calendar access to see today's schedule.")
                .font(.system(size: 12))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer()
            Button("Grant…") { IPC.post(IPC.Name.grantCalendar) }
                .buttonStyle(HoverButtonStyle())
                .font(.system(size: 11))
                .foregroundStyle(theme)
        }
        .padding(.vertical, 14)
    }
}

private func jumpLink(_ title: String, to destination: MainDestination, dark: Bool) -> some View {
    JumpLink(title: title, destination: destination, dark: dark)
}

private struct JumpLink: View {
    let title: String
    let destination: MainDestination
    let dark: Bool
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.home.rawValue

    var body: some View {
        Button {
            mainWindowSection = destination.rawValue
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(DashSkin.accentDeep(dark))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .padding(.top, 10)
    }
}

private struct UsageSummaryCard: View {
    let dark: Bool
    @ObservedObject private var model = DashboardModel.shared
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("presenterBlurMoney", store: SharedDefaults.store) private var presenterBlurMoney =
        true

    private var blurMoney: Bool { presenterState.active && presenterBlurMoney }

    private static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func day(_ offset: Int) -> HeatDay? {
        let cal = Calendar.current
        let date = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: Date()))!
        return model.heatDetail[Self.ymd.string(from: date)]
    }

    private var lastDays: [(date: Date, cost: Double, tokens: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<14).reversed().map { offset in
            let date = cal.date(byAdding: .day, value: -offset, to: today)!
            let detail = model.heatDetail[Self.ymd.string(from: date)]
            return (date, detail?.cost ?? 0, detail?.tokens ?? 0)
        }
    }

    private var weekModels: [NamedValue] {
        HomeMath.topModels(days: (0..<7).map(day))
    }

    var body: some View {
        SkinCard(title: "Agent usage", note: "last 14 days", dark: dark) {
            if model.loaded {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 24) {
                        stat(
                            "Today", cost: day(0)?.cost ?? 0,
                            tokens: day(0)?.tokens ?? 0)
                        stat(
                            "This week",
                            cost: (0..<7).reduce(0) { $0 + (day($1)?.cost ?? 0) },
                            tokens: (0..<7).reduce(0) { $0 + (day($1)?.tokens ?? 0) })
                    }
                    chart
                    if !weekModels.isEmpty {
                        WrapHStack(spacing: 12, lineSpacing: 4) {
                            ForEach(Array(weekModels.enumerated()), id: \.element.id) { i, entry in
                                HStack(spacing: 5) {
                                    Circle()
                                        .fill(DashPalette.categorical(i, dark: dark))
                                        .frame(width: 7, height: 7)
                                    Text(entry.name)
                                        .font(.system(size: 11))
                                        .foregroundStyle(DashSkin.inkSoft(dark))
                                    Text(DashFmt.tokens(entry.value))
                                        .font(DashSkin.mono(10))
                                        .foregroundStyle(DashSkin.inkFaint(dark))
                                        .presenterBlur(blurMoney)
                                }
                            }
                        }
                    }
                    jumpLink("Open Agent Usage", to: .dashboard, dark: dark)
                }
            } else {
                Text(model.loadAttempted ? "No usage data yet" : "Loading usage data…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
    }

    private func stat(_ label: String, cost: Double, tokens: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(DashSkin.mono(9.5)).tracking(1.3)
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(DashFmt.usd(cost))
                .font(DashSkin.serif(24))
                .foregroundStyle(DashSkin.ink(dark))
                .presenterBlur(blurMoney)
            Text("\(DashFmt.tokens(tokens)) tokens")
                .font(.system(size: 11))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .presenterBlur(blurMoney)
        }
    }

    private var chart: some View {
        Chart(lastDays, id: \.date) { entry in
            BarMark(
                x: .value("Day", entry.date, unit: .day),
                y: .value("Cost", entry.cost)
            )
            .cornerRadius(2)
            .foregroundStyle(
                Calendar.current.isDateInToday(entry.date)
                    ? DashSkin.accent(dark) : DashSkin.accent(dark).opacity(0.45))
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(.dateTime.day()))
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .frame(height: 64)
    }
}

private struct LimitsSummaryCard: View {
    let dark: Bool
    @AppStorage("warnPercent") private var warn = 60
    @AppStorage("critPercent") private var crit = 85
    @State private var latest: DashLimitPoint?
    @AppStorage("limitsProvider", store: SharedDefaults.store) private var selectedRaw =
        LimitProvider.claude.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var providers: [LimitProvider] { DashLimits.availableProviders() }
    private var selected: LimitProvider {
        get {
            let saved = LimitProvider(rawValue: selectedRaw) ?? .claude
            return providers.contains(saved) ? saved : providers.first ?? saved
        }
        nonmutating set { selectedRaw = newValue.rawValue }
    }

    var body: some View {
        SkinCard(title: "Rate limits", note: "session · weekly", dark: dark) {
            VStack(alignment: .leading, spacing: 14) {
                ProviderSwitchButton(
                    selection: Binding(get: { selected }, set: { selected = $0 }),
                    providers: providers, color: DashSkin.ink(dark), size: 15)
                if let latest {
                    HStack(alignment: .top, spacing: 20) {
                        gauge("Session (5h)", value: latest.s, reset: latest.sr)
                        gauge("Weekly", value: latest.w, reset: latest.wr)
                    }
                    .frame(maxWidth: .infinity)
                    HStack {
                        Text("As of \(latest.t.formatted(date: .omitted, time: .shortened))")
                            .font(DashSkin.mono(9))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                        Spacer()
                        LimitsRefreshButton(dark: dark) { reload() }
                    }
                    jumpLink("Open Agent Usage", to: .dashboard, dark: dark)
                } else {
                    HStack {
                        Text("Collecting limit history…")
                            .font(.system(size: 12.5))
                            .foregroundStyle(DashSkin.inkFaint(dark))
                            .frame(maxWidth: .infinity, minHeight: 90)
                        LimitsRefreshButton(dark: dark) { reload() }
                    }
                }
            }
        }
        .task { reload() }
        .onChange(of: selectedRaw) { reload() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            reload()
        }
    }

    private func reload() {
        latest = DashLimits.loadLatest(provider: selected)
    }

    private func barColor(_ value: Double) -> Color {
        if value >= Double(crit) { return .red }
        if value >= Double(warn) { return .orange }
        return DashSkin.sage
    }

    private func gauge(_ label: String, value: Double?, reset: Date?) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.08), style: StrokeStyle(lineWidth: 9))
                if let value {
                    Circle()
                        .trim(from: 0, to: min(value, 100) / 100)
                        .stroke(
                            barColor(value),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                }
                Text(value.map { "\(Int($0))%" } ?? "-")
                    .font(DashSkin.serif(22))
                    .foregroundStyle(value.map(barColor) ?? DashSkin.inkFaint(dark))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(
                        Motion.animation(Motion.settle, reduceMotion: reduceMotion), value: value)
            }
            .frame(width: 92, height: 92)
            .padding(5)
            VStack(spacing: 2) {
                Text(label.uppercased())
                    .font(DashSkin.mono(9.5)).tracking(1.3)
                    .foregroundStyle(DashSkin.inkFaint(dark))
                if let reset {
                    Text("Resets \(reset.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MusicCard: View {
    let dark: Bool
    @ObservedObject private var remote = MusicRemote.shared
    @ObservedObject private var visibility = WindowVisibility.shared
    @StateObject private var presenterState = PresenterState.shared
    @AppStorage("theme", store: SharedDefaults.store) private var themeName = "accent"
    @AppStorage("presenterBlurMusic", store: SharedDefaults.store) private var presenterBlurMusic =
        true

    private var theme: Color { themeColor(themeName) }
    private var blur: Bool { presenterState.active && presenterBlurMusic }

    private var upNext: [Track] {
        remote.tracks.filter { $0.url.lastPathComponent != remote.currentFile }.prefix(4)
            .map { $0 }
    }

    var body: some View {
        SkinCard(
            title: "Music", note: remote.tracks.isEmpty ? "" : "\(remote.tracks.count) tracks",
            dark: dark
        ) {
            VStack(alignment: .leading, spacing: 10) {
                if let track = remote.current {
                    nowPlaying(track)
                    Divider().opacity(0.4)
                }
                if remote.tracks.isEmpty {
                    Text("Drop audio files into your music folder to play them here.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .frame(maxWidth: .infinity, minHeight: 70)
                } else {
                    ForEach(upNext) { track in
                        trackRow(track)
                    }
                }
                jumpLink("Open Music", to: .music, dark: dark)
            }
        }
        .onAppear { remote.start() }
    }

    private var elapsedText: some View {
        Text("\(TrackMeta.timeLabel(remote.elapsed)) / \(TrackMeta.timeLabel(remote.duration))")
            .font(DashSkin.mono(9.5))
            .foregroundStyle(DashSkin.inkFaint(dark))
    }

    private func nowPlaying(_ track: Track) -> some View {
        HStack(spacing: 10) {
            HomeArtworkThumb(track: track, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(DashSkin.ink(dark))
                    .presenterBlur(blur)
                if remote.isPlaying, visibility.visible {
                    TimelineView(.periodic(from: MusicTick.epoch, by: 1)) { _ in
                        elapsedText
                    }
                } else {
                    elapsedText
                }
            }
            PlaybackWave(playing: remote.isPlaying, color: theme.opacity(0.9), maxHeight: 14)
            Spacer(minLength: 6)
            Button {
                remote.playPause()
            } label: {
                Image(systemName: remote.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
            Button {
                remote.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(theme)
            }
            .buttonStyle(HoverButtonStyle())
        }
    }

    private func trackRow(_ track: Track) -> some View {
        Button {
            remote.toggle(track)
        } label: {
            HStack(spacing: 8) {
                HomeArtworkThumb(track: track, size: 26)
                Text(track.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .presenterBlur(blur)
                Spacer(minLength: 6)
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

private struct HomeArtworkThumb: View {
    let track: Track
    var size: CGFloat = 36
    @State private var artwork: NSImage?

    var body: some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [
                            Color(hue: track.hue, saturation: 0.55, brightness: 0.45),
                            Color(hue: track.hue, saturation: 0.6, brightness: 0.22),
                        ],
                        startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.36))
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
        .task(id: track.id) { artwork = await TrackMeta.artwork(for: track) }
    }
}
