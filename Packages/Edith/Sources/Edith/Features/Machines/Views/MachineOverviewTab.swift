import EdithKit
import SwiftUI

struct SparkSamples: VectorArithmetic {
    var values: [Double]

    static var zero: SparkSamples { SparkSamples(values: []) }

    private static func merge(
        _ lhs: [Double], _ rhs: [Double], _ combine: (Double, Double) -> Double
    ) -> [Double] {
        let count = max(lhs.count, rhs.count)
        guard count > 0 else { return [] }
        return (0..<count).map { index in
            let left = lhs.count - count + index
            let right = rhs.count - count + index
            return combine(
                left >= 0 ? lhs[left] : (lhs.first ?? 0),
                right >= 0 ? rhs[right] : (rhs.first ?? 0))
        }
    }

    static func + (lhs: SparkSamples, rhs: SparkSamples) -> SparkSamples {
        SparkSamples(values: merge(lhs.values, rhs.values, +))
    }

    static func - (lhs: SparkSamples, rhs: SparkSamples) -> SparkSamples {
        SparkSamples(values: merge(lhs.values, rhs.values, -))
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}

struct SparkShape: Shape {
    var samples: SparkSamples
    let maximum: Double
    let capacity: Int
    let filled: Bool

    var animatableData: SparkSamples {
        get { samples }
        set { samples = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let values = samples.values
        guard values.count > 1 else { return Path() }
        let scale = max(maximum, values.max() ?? 1, 0.001)
        let slots = max(capacity, values.count)
        let step = rect.width / CGFloat(slots - 1)
        let offset = CGFloat(slots - values.count) * step
        let points = values.enumerated().map { index, value in
            CGPoint(
                x: rect.minX + offset + CGFloat(index) * step,
                y: rect.maxY - rect.height * CGFloat(min(max(value, 0), scale) / scale))
        }
        var path = Path()
        if filled { path.move(to: CGPoint(x: points[0].x, y: rect.maxY)) }
        path.addLines(filled ? points : Array(points))
        if filled {
            path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

enum MetricsCadence {
    static let sampleInterval = 2.0
    static let dockerInterval = 4.0
}

struct Sparkline: View {
    let values: [Double]
    let maximum: Double
    let color: Color
    var cadence = MetricsCadence.sampleInterval
    var capacity = MachineSession.historyLength

    var body: some View {
        let samples = SparkSamples(values: values)
        ZStack {
            SparkShape(samples: samples, maximum: maximum, capacity: capacity, filled: true)
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.28), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
            SparkShape(samples: samples, maximum: maximum, capacity: capacity, filled: false)
                .stroke(color, style: StrokeStyle(lineWidth: UIScale.pt(1.6), lineJoin: .round))
        }
        .animation(.linear(duration: cadence), value: values)
    }
}

struct MeterBar: View {
    let fraction: Double
    let color: Color
    let track: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule()
                    .fill(color)
                    .frame(width: max(UIScale.pt(3), proxy.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: UIScale.pt(6))
        .animation(.easeInOut(duration: MetricsCadence.sampleInterval * 0.8), value: fraction)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let fraction: Double?
    let history: [Double]
    let maximum: Double
    let color: Color
    let footnote: String
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .tracking(UIScale.pt(0.7))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
                Text(value)
                    .font(DashSkin.serif(21))
                    .foregroundStyle(DashSkin.ink(dark))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.6), value: value)
            }
            if let fraction {
                MeterBar(fraction: fraction, color: color, track: DashSkin.line(dark))
            }
            Sparkline(values: history, maximum: maximum, color: color)
                .frame(height: UIScale.pt(46))
            if !footnote.isEmpty {
                Text(footnote)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBar(cornerRadius: 14, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }
}

struct NetworkSparkline: View {
    let downloadValues: [Double]
    let uploadValues: [Double]

    private var maximum: Double {
        max(max(downloadValues.max() ?? 0, uploadValues.max() ?? 0), 1)
    }

    var body: some View {
        ZStack {
            SparkShape(
                samples: SparkSamples(values: downloadValues), maximum: maximum,
                capacity: MachineSession.historyLength, filled: true
            )
            .fill(
                LinearGradient(
                    colors: [DashSkin.networkDownload.opacity(0.18), .clear],
                    startPoint: .top, endPoint: .bottom))
            SparkShape(
                samples: SparkSamples(values: downloadValues), maximum: maximum,
                capacity: MachineSession.historyLength, filled: false
            )
            .stroke(
                DashSkin.networkDownload,
                style: StrokeStyle(lineWidth: UIScale.pt(1.6), lineJoin: .round))
            SparkShape(
                samples: SparkSamples(values: uploadValues), maximum: maximum,
                capacity: MachineSession.historyLength, filled: false
            )
            .stroke(
                DashSkin.networkUpload,
                style: StrokeStyle(lineWidth: UIScale.pt(1.6), lineJoin: .round))
        }
        .animation(.easeInOut(duration: 0.6), value: downloadValues)
        .animation(.easeInOut(duration: 0.6), value: uploadValues)
    }
}

struct NetworkSpeedLoadingSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(spacing: UIScale.pt(12)) {
                speed(labelWidth: 54, valueWidth: 78)
                speed(labelWidth: 42, valueWidth: 68)
            }
            SkeletonBlock(height: 34, corner: 6)
            SkeletonBlock(width: 116, height: 11, corner: 3)
        }
    }

    private func speed(labelWidth: Double, valueWidth: Double) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            HStack(spacing: UIScale.pt(4)) {
                SkeletonBlock(width: 9, height: 9, corner: 2)
                SkeletonBlock(width: labelWidth, height: 10, corner: 3)
            }
            SkeletonBlock(width: valueWidth, height: 18, corner: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NetworkMetricCard: View {
    let measurement: InternetSpeedMeasurement?
    let downloadHistory: [Double]
    let uploadHistory: [Double]
    let isTesting: Bool
    let error: String?
    let dark: Bool
    let refresh: () -> Void

    var body: some View {
        Group {
            if isTesting {
                SkeletonGroup { cardContent }
            } else {
                cardContent
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetBar(cornerRadius: 14, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            HStack(alignment: .center) {
                Text("INTERNET SPEED")
                    .font(.system(size: UIScale.pt(9.5), weight: .semibold))
                    .tracking(UIScale.pt(0.7))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Spacer()
                if isTesting {
                    SkeletonBlock(width: 13, height: 13, corner: 4)
                } else {
                    Button(action: refresh) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.edith(.borderless))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .help("Test again")
                }
            }
            if isTesting, measurement == nil {
                NetworkSpeedLoadingSkeleton()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Testing internet speed")
            } else {
                HStack(spacing: UIScale.pt(12)) {
                    speed(
                        "Download", value: measurement?.downloadBitsPerSecond,
                        systemImage: "arrow.down", color: DashSkin.networkDownload)
                    speed(
                        "Upload", value: measurement?.uploadBitsPerSecond,
                        systemImage: "arrow.up", color: DashSkin.networkUpload)
                }
                NetworkSparkline(
                    downloadValues: downloadHistory, uploadValues: uploadHistory
                )
                .frame(height: UIScale.pt(34))
                status
            }
        }
    }

    private func speed(
        _ title: String, value: Double?, systemImage: String, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Label(title, systemImage: systemImage)
                .font(.system(size: UIScale.pt(9.5), weight: .medium))
                .foregroundStyle(color)
            Text(value.map(InternetSpeedFormatter.string) ?? "–")
                .font(DashSkin.serif(17))
                .foregroundStyle(DashSkin.ink(dark))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.6), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map(InternetSpeedFormatter.string) ?? "Not tested")
    }

    @ViewBuilder
    private var status: some View {
        if isTesting {
            ZStack(alignment: .leading) {
                SkeletonBlock(width: 74, height: 11, corner: 3)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Testing internet speed again")
        } else if let error {
            Text(error)
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.danger)
                .lineLimit(1)
                .help(error)
        } else if let measurement {
            Text("Tested \(measurement.measuredAt, style: .relative)")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        } else {
            Text("Waiting to test this machine")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }
}

struct MetricsGridLayout: Layout {
    let spacing: CGFloat
    var minimumColumnWidth = UIScale.pt(238)

    private func columnCount(width: CGFloat, itemCount: Int) -> Int {
        guard width.isFinite else { return 1 }
        let fitting = max(1, Int((width + spacing) / (minimumColumnWidth + spacing)))
        return min(itemCount, min(3, fitting))
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [(Range<Int>, CGFloat, CGFloat)] {
        guard !subviews.isEmpty else { return [] }
        let width = width.isFinite ? width : minimumColumnWidth
        let columns = columnCount(width: width, itemCount: subviews.count)
        return stride(from: 0, to: subviews.count, by: columns).map { start in
            let end = min(start + columns, subviews.count)
            let range = start..<end
            let itemWidth = (width - spacing * CGFloat(range.count - 1)) / CGFloat(range.count)
            let height = range.reduce(0) { current, index in
                max(
                    current,
                    subviews[index].sizeThatFits(
                        ProposedViewSize(width: itemWidth, height: nil)
                    ).height)
            }
            return (range, itemWidth, height)
        }
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? minimumColumnWidth
        let rows = rows(width: width, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.2 } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.0 {
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: row.1, height: row.2))
                x += row.1 + spacing
            }
            y += row.2 + spacing
        }
    }
}

struct MachineOverviewTab: View {
    let session: MachineSession
    let model: MachinesModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    private var dark: Bool { scheme == .dark }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if session.sample == nil, !session.state.isConnected {
                    connectionNotice
                }
                if session.sample == nil {
                    MachineOverviewSkeleton(dark: dark)
                } else {
                    loaded
                }
            }
            .pageContent(compact)
        }
        .machineActivity(session, kind: .internetSpeed)
    }

    @ViewBuilder
    private var loaded: some View {
        identityCard
        metricsGrid
        if let slow = session.slow {
            if !slow.disks.isEmpty {
                SkinCard(title: "Storage", dark: dark) { storage(slow) }
            }
        } else {
            MeterRowsSkeleton(title: "Storage", rows: 2, dark: dark)
        }
        if let slow = session.slow, !slow.temps.isEmpty || slow.gpu != nil {
            SkinCard(title: "Hardware", dark: dark) { hardware(slow) }
        }
        if !session.facts.who.isEmpty || session.facts.updatesAvailable != nil {
            SkinCard(title: "Host", dark: dark) { hostFacts }
        }
    }

    private var connectionNotice: some View {
        HStack(spacing: UIScale.pt(10)) {
            if session.state.isBusy {
                SkeletonGroup {
                    HStack(spacing: UIScale.pt(10)) {
                        SkeletonBlock(width: 13, height: 13, corner: 6.5)
                        SkeletonBlock(width: 226, height: 10, corner: 2)
                    }
                }
                .accessibilityLabel(MachineStatusStyle.detail(session.state))
            } else {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundStyle(DashSkin.inkFaint(dark))
                Text(MachineStatusStyle.detail(session.state))
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            Spacer(minLength: 0)
            if case .disconnected = session.state {
                Button("Connect") { model.performConnection(.connect, for: session) }
            }
        }
        .padding(UIScale.pt(14))
        .widgetBar(cornerRadius: 12, fill: DashSkin.paper2(dark))
    }

    private var identityCard: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkFaint(dark))
            Text(uptimeText)
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
            Spacer(minLength: 0)
            if let hello = session.hello {
                Text("\(hello.os)  ·  \(hello.arch)")
                    .font(DashSkin.mono(10.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(10))
        .widgetBar(cornerRadius: 12, fill: DashSkin.paper2(dark), stroke: DashSkin.line(dark))
    }

    private var uptimeText: String {
        guard let sample = session.sample else { return "Waiting for the first sample" }
        return "Up \(ByteFormatter.duration(sample.uptime))"
    }

    private var metricsGrid: some View {
        MetricsGridLayout(spacing: UIScale.pt(12)) {
            metricCard(
                "CPU", value: session.sample.map { String(format: "%.0f%%", $0.cpu.total) } ?? "—",
                fraction: (session.sample?.cpu.total ?? 0) / 100, history: session.cpuHistory,
                maximum: 100, color: DashSkin.accent(dark),
                footnote: session.sample.map { sample in
                    sample.cpu.steal > 1
                        ? String(format: "steal %.0f%%", sample.cpu.steal)
                        : "\(session.hello?.cores ?? sample.cpu.cores.count) cores"
                } ?? "")
            metricCard(
                "Memory",
                value: session.sample.map { String(format: "%.0f%%", $0.mem.usedPercent) } ?? "—",
                fraction: (session.sample?.mem.usedPercent ?? 0) / 100, history: session.memHistory,
                maximum: 100, color: DashSkin.sage,
                footnote: session.sample.map {
                    "\(ByteFormatter.string($0.mem.usedKB * 1024)) of "
                        + ByteFormatter.string($0.mem.totalKB * 1024)
                } ?? "")
            NetworkMetricCard(
                measurement: session.internetSpeed,
                downloadHistory: session.internetDownloadHistory,
                uploadHistory: session.internetUploadHistory,
                isTesting: session.isTestingInternetSpeed,
                error: session.internetSpeedError,
                dark: dark,
                refresh: session.refreshInternetSpeed)
        }
    }

    private func metricCard(
        _ title: String, value: String, fraction: Double?, history: [Double], maximum: Double,
        color: Color, footnote: String
    ) -> some View {
        MetricCard(
            title: title, value: value, fraction: fraction, history: history, maximum: maximum,
            color: color, footnote: footnote, dark: dark)
    }

    private func storage(_ slow: MachineSlow) -> some View {
        VStack(spacing: UIScale.pt(10)) {
            ForEach(slow.disks) { disk in
                VStack(alignment: .leading, spacing: UIScale.pt(5)) {
                    HStack {
                        Text(disk.mount)
                            .font(.system(size: UIScale.pt(12), weight: .medium))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Spacer()
                        Text(
                            "\(ByteFormatter.string(disk.usedKB * 1024)) of "
                                + ByteFormatter.string(disk.totalKB * 1024)
                        )
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    }
                    MeterBar(
                        fraction: disk.usedPercent / 100,
                        color: disk.usedPercent > FleetMath.diskWarningPercent
                            ? DashSkin.danger
                            : (disk.usedPercent > 75 ? DashSkin.warn : DashSkin.accent(dark)),
                        track: DashSkin.line(dark))
                }
            }
        }
    }

    private func network(_ sample: MachineSample) -> some View {
        VStack(spacing: UIScale.pt(6)) {
            ForEach(sample.net.ifaces.filter { !$0.virtual }, id: \.n) { iface in
                HStack {
                    Text(iface.n)
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer()
                    Label(ByteFormatter.rate(iface.rxBps), systemImage: "arrow.down")
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                    Label(ByteFormatter.rate(iface.txBps), systemImage: "arrow.up")
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
        }
    }

    private func hardware(_ slow: MachineSlow) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            if let gpu = slow.gpu {
                HStack {
                    Text(gpu.name)
                        .font(.system(size: UIScale.pt(12), weight: .medium))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer()
                    Text(
                        "\(gpu.util)%  ·  \(gpu.memUsedMB) of \(gpu.memTotalMB) MB  ·  \(gpu.temp)°C"
                    )
                    .font(DashSkin.mono(10.5))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            if let battery = slow.battery {
                HStack {
                    Text("Battery")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.ink(dark))
                    Spacer()
                    Text("\(battery.percent)%  ·  \(battery.status)")
                        .font(DashSkin.mono(10.5))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            if !slow.temps.isEmpty {
                let columns = [
                    GridItem(.adaptive(minimum: UIScale.pt(150)), spacing: UIScale.pt(8))
                ]
                LazyVGrid(columns: columns, alignment: .leading, spacing: UIScale.pt(6)) {
                    ForEach(slow.temps, id: \.label) { temp in
                        HStack(spacing: UIScale.pt(6)) {
                            Text(temp.label)
                                .font(.system(size: UIScale.pt(11)))
                                .foregroundStyle(DashSkin.inkSoft(dark))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Text(String(format: "%.0f°C", temp.c))
                                .font(DashSkin.mono(10.5))
                                .foregroundStyle(
                                    temp.c > 85 ? DashSkin.danger : DashSkin.inkFaint(dark))
                        }
                    }
                }
            }
        }
    }

    private var hostFacts: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
            if let updates = session.facts.updatesAvailable, updates > 0 {
                Label(
                    "\(updates) package update\(updates == 1 ? "" : "s") available",
                    systemImage: "shippingbox.and.arrow.backward"
                )
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            }
            ForEach(session.facts.who, id: \.self) { line in
                Label(line, systemImage: "person")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
    }
}
