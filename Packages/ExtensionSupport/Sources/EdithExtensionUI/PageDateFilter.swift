import EdithExtensionCore
import SwiftUI

public struct PageDateFilter: View {
    @Environment(\.colorScheme) private var scheme
    @Binding private var selection: DateFilterSelection
    @State private var customOpen = false

    private let presets: [DateFilterPreset]
    private let months: [DateFilterMonth]
    private let earliest: DateFilterDay?
    private let showsStepper: Bool
    private let now: Date
    private let calendar: Calendar

    public init(
        selection: Binding<DateFilterSelection>,
        presets: [DateFilterPreset] = DateFilterPreset.allCases,
        months: [DateFilterMonth] = [],
        earliest: DateFilterDay? = nil,
        showsStepper: Bool = true,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        _selection = selection
        self.presets = presets
        self.months = months
        self.earliest = earliest
        self.showsStepper = showsStepper
        self.now = now
        self.calendar = calendar
    }

    public var body: some View {
        ForEach(quickPresets) { preset in
            PageChip(preset.chipTitle, active: selection == .preset(preset)) {
                choose(.preset(preset))
            }
            .accessibilityLabel(preset.title)
        }
        moreMenu
        if showsStepper, selection.isSteppable { stepper }
    }

    private var quickPresets: [DateFilterPreset] {
        DateFilterPreset.quick.filter(presets.contains)
    }

    private var groups: [[DateFilterPreset]] {
        DateFilterPreset.groups
            .map { $0.filter(presets.contains) }
            .filter { !$0.isEmpty }
    }

    private var activeIsQuick: Bool {
        guard case .preset(let preset) = selection else { return false }
        return quickPresets.contains(preset)
    }

    private var moreTitle: String {
        activeIsQuick ? "More" : selection.title(calendar: calendar)
    }

    private var moreMenu: some View {
        PageMenuChip(moreTitle, systemImage: "calendar", active: !activeIsQuick) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                Section {
                    ForEach(group) { preset in
                        menuItem(preset.title, active: selection == .preset(preset)) {
                            choose(.preset(preset))
                        }
                    }
                }
            }
            if !months.isEmpty {
                Section {
                    Menu("Browse months") {
                        ForEach(months) { month in
                            menuItem(month.title(calendar: calendar), active: isActive(month)) {
                                choose(.month(month))
                            }
                        }
                    }
                }
            }
            Section {
                Button("Custom range…") { customOpen = true }
            }
        }
        .accessibilityLabel(activeIsQuick ? "More date ranges" : "Date range, \(moreTitle)")
        .help("More date ranges")
        .popover(isPresented: $customOpen, arrowEdge: .bottom) {
            PageDateRangePicker(
                range: selection.range(now: now, calendar: calendar), earliest: earliest,
                now: now, calendar: calendar,
                onApply: { range in
                    choose(.custom(range))
                    customOpen = false
                },
                onCancel: { customOpen = false })
        }
    }

    @ViewBuilder
    private func menuItem(
        _ title: String, active: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if active {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func isActive(_ month: DateFilterMonth) -> Bool {
        selection.canonical(now: now, calendar: calendar)
            == DateFilterSelection.month(month).canonical(now: now, calendar: calendar)
    }

    private var stepper: some View {
        let period = selection.periodLabel(now: now, calendar: calendar)
        return HStack(spacing: UIScale.pt(4)) {
            PageIconChip(systemImage: "chevron.left", label: "Previous period") { step(-1) }
                .disabled(
                    !selection.canStepBackward(earliest: earliest, now: now, calendar: calendar))
            if period != moreTitle {
                Text(period)
                    .font(PageMetrics.chipFont)
                    .monospacedDigit()
                    .foregroundStyle(DashSkin.ink(scheme == .dark))
                    .lineLimit(1)
                    .padding(.horizontal, UIScale.pt(4))
                    .accessibilityLabel("Period, \(period)")
            }
            PageIconChip(systemImage: "chevron.right", label: "Next period") { step(1) }
                .disabled(!selection.canStepForward(now: now, calendar: calendar))
        }
        .fixedSize()
    }

    private func step(_ steps: Int) {
        selection = selection.stepped(by: steps, now: now, calendar: calendar)
    }

    private func choose(_ next: DateFilterSelection) {
        selection = next.canonical(now: now, calendar: calendar)
    }
}
