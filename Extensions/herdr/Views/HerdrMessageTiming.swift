import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HerdrValueDial: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var wraps = false
    var display: (Int) -> String = { String(format: "%d", $0) }

    @State private var dragBase: Int?
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: UIScale.pt(2)) {
            stepButton("chevron.up", step)
            Text(display(value))
                .font(.edithText(.largeTitle, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DashSkin.ink(dark))
                .frame(minWidth: UIScale.pt(64))
                .contentShape(Rectangle())
                .gesture(scrub)
            Text(label)
                .font(.edithText(.caption).weight(.semibold))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .textCase(.uppercase)
            stepButton("chevron.down", -step)
        }
        .padding(.vertical, UIScale.pt(4))
        .frame(maxWidth: .infinity)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(display(value))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? step : -step)
        }
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { gesture in
                if dragBase == nil { dragBase = value }
                let steps = Int((-gesture.translation.height / 16).rounded())
                value = clamped((dragBase ?? value) + steps * step)
            }
            .onEnded { _ in dragBase = nil }
    }

    private func stepButton(_ symbol: String, _ delta: Int) -> some View {
        Button {
            nudge(delta)
        } label: {
            Image(systemName: symbol)
                .font(.edithText(.subheadline).weight(.bold))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .frame(width: UIScale.pt(36), height: UIScale.pt(22))
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
    }

    private func nudge(_ delta: Int) {
        value = clamped(value + delta)
    }

    private func clamped(_ next: Int) -> Int {
        guard wraps else { return min(range.upperBound, max(range.lowerBound, next)) }
        let span = range.upperBound - range.lowerBound + step
        let shifted = next - range.lowerBound
        let mod = ((shifted % span) + span) % span
        return range.lowerBound + mod
    }
}

struct HerdrTimingChoice: View {
    @Binding var mode: HerdrMessageDraft.Delivery

    var body: some View {
        EdithSegmentedPicker(
            "When to send", selection: $mode, options: HerdrMessageDraft.Delivery.allCases,
            label: \.title
        )
        .labelsHidden()
    }
}

struct HerdrAfterPicker: View {
    @Binding var hours: Int
    @Binding var minutes: Int
    let moment: String
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private static let presets: [(String, Int, Int)] = [
        ("5m", 0, 5), ("15m", 0, 15), ("30m", 0, 30), ("1h", 1, 0), ("2h", 2, 0), ("4h", 4, 0),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text(delayTitle)
                .font(.edithText(.title3).weight(.semibold))
                .foregroundStyle(DashSkin.ink(dark))
            Text(moment)
                .font(.edithText(.callout))
                .foregroundStyle(DashSkin.accent(dark))
            presetRow
            HStack(spacing: UIScale.pt(8)) {
                HerdrValueDial(label: "Hours", value: $hours, range: 0...23)
                HerdrValueDial(label: "Minutes", value: $minutes, range: 0...59)
            }
        }
    }

    private var delayTitle: String {
        let phrase = HerdrHookSchedule.delayPhrase(hours: hours, minutes: minutes)
        return "In \(phrase.dropFirst(3))"
    }

    private var presetRow: some View {
        HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            ForEach(Self.presets, id: \.0) { preset in
                PageChip(preset.0, active: hours == preset.1 && minutes == preset.2) {
                    hours = preset.1
                    minutes = preset.2
                }
            }
        }
    }
}

struct HerdrAtPicker: View {
    @Binding var dayOffset: Int
    @Binding var hour: Int
    @Binding var minute: Int
    let now: Date
    let moment: String
    let passed: Bool
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var calendar: Calendar { .current }
    private static let suggestions = [9, 12, 15, 18, 21]

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            Text(passed ? "That time has already passed" : leadingCapital(moment))
                .font(.edithText(.title3).weight(.semibold))
                .foregroundStyle(passed ? Color.orange : DashSkin.ink(dark))
            dayStrip
            HStack(spacing: UIScale.pt(8)) {
                HerdrValueDial(
                    label: "Hour", value: $hour, range: 0...23, wraps: true,
                    display: { value in
                        let wrapped = value % 12
                        return wrapped == 0 ? "12" : String(wrapped)
                    })
                HerdrValueDial(
                    label: "Minute", value: $minute, range: 0...59, wraps: true,
                    display: { String(format: "%02d", $0) })
                period
            }
            suggestionRow
        }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
                ForEach(0..<7, id: \.self) { offset in
                    PageChip(dayTitle(offset), active: dayOffset == offset) {
                        dayOffset = offset
                    }
                }
            }
            .padding(.vertical, UIScale.pt(1))
        }
    }

    private enum Period: String, CaseIterable, Hashable {
        case am = "AM"
        case pm = "PM"
    }

    private var periodSelection: Binding<Period> {
        Binding(
            get: { hour >= 12 ? .pm : .am },
            set: { next in
                guard (next == .pm) != (hour >= 12) else { return }
                hour = (hour + 12) % 24
            })
    }

    private var period: some View {
        EdithSegmentedPicker(
            "Morning or afternoon", selection: periodSelection, options: Period.allCases,
            label: \.rawValue
        )
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private var suggestionRow: some View {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: dayOffset, to: start) ?? start
        return HStack(spacing: UIScale.pt(PageMetrics.controlSpacing)) {
            ForEach(Self.suggestions, id: \.self) { suggestion in
                suggestionButton(suggestion, on: day)
            }
        }
    }

    @ViewBuilder
    private func suggestionButton(_ suggestion: Int, on day: Date) -> some View {
        let when = calendar.date(bySettingHour: suggestion, minute: 0, second: 0, of: day)
        if let when, when > now {
            PageChip(
                HerdrHookSchedule.clockText(when, calendar: calendar),
                active: hour == suggestion && minute == 0
            ) {
                hour = suggestion
                minute = 0
            }
        }
    }

    private func leadingCapital(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    private func dayTitle(_ offset: Int) -> String {
        if offset == 0 { return "Today" }
        if offset == 1 { return "Tomorrow" }
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        let weekday = calendar.shortWeekdaySymbols[calendar.component(.weekday, from: day) - 1]
        return "\(weekday) \(calendar.component(.day, from: day))"
    }
}
