import EdithKit
import SwiftUI

struct MouseControlsRows: View {
    @AppStorage(AppStorageKeys.Mouse.enabled, store: SharedDefaults.store) private var enabled =
        false
    @AppStorage(AppStorageKeys.Mouse.smoothScroll, store: SharedDefaults.store) private
        var smoothScroll = true
    @AppStorage(AppStorageKeys.Mouse.scrollStep, store: SharedDefaults.store) private
        var scrollStep =
        MouseControlSupport.defaultScrollStep
    @AppStorage(AppStorageKeys.Mouse.reverseVertical, store: SharedDefaults.store) private
        var reverseVertical = false
    @AppStorage(AppStorageKeys.Mouse.reverseHorizontal, store: SharedDefaults.store) private
        var reverseHorizontal = false
    @AppStorage(AppStorageKeys.Mouse.focusFollowsPointer, store: SharedDefaults.store) private
        var focusFollowsPointer = false
    @AppStorage(AppStorageKeys.Mouse.focusDelay, store: SharedDefaults.store) private
        var focusDelay =
        MouseControlSupport.defaultFocusDelay
    @AppStorage(AppStorageKeys.Mouse.sideNavigation, store: SharedDefaults.store) private
        var sideNavigation = true
    @AppStorage(AppStorageKeys.Mouse.button4Action, store: SharedDefaults.store) private
        var button4Action = MouseButtonAction.automatic.rawValue
    @AppStorage(AppStorageKeys.Mouse.button5Action, store: SharedDefaults.store) private
        var button5Action = MouseButtonAction.automatic.rawValue
    @AppStorage(AppStorageKeys.Mouse.button6Action, store: SharedDefaults.store) private
        var button6Action = MouseButtonAction.passThrough.rawValue
    @AppStorage(AppStorageKeys.Mouse.button7Action, store: SharedDefaults.store) private
        var button7Action = MouseButtonAction.passThrough.rawValue
    @AppStorage(AppStorageKeys.Mouse.button8Action, store: SharedDefaults.store) private
        var button8Action = MouseButtonAction.passThrough.rawValue
    @AppStorage(AppStorageKeys.Mouse.excludedApps, store: SharedDefaults.store) private
        var excludedApps = ""
    @State private var tab = "general"

    var body: some View {
        Section {
            Picker("", selection: $tab) {
                Text("General").tag("general")
                Text("Buttons").tag("buttons")
                Text("Apps").tag("apps")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Group {
            switch tab {
            case "buttons": buttonSections
            case "apps": appSections
            default: generalSections
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    @ViewBuilder private var generalSections: some View {
        Section("Wheel") {
            Toggle(
                "Smooth discrete wheel movement",
                isOn: $smoothScroll.configured(AppStorageKeys.Mouse.smoothScroll))
            if smoothScroll {
                LabeledContent("Distance") {
                    HStack(spacing: UIScale.pt(8)) {
                        Slider(
                            value: scrollStepBinding,
                            in: Double(
                                MouseControlSupport.scrollStepRange.lowerBound)...Double(
                                    MouseControlSupport.scrollStepRange.upperBound)
                        )
                        .frame(width: UIScale.pt(180))
                        Text("\(scrollStep) px")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(
                "Reverse vertical wheel",
                isOn: $reverseVertical.configured(AppStorageKeys.Mouse.reverseVertical))
            Toggle(
                "Reverse horizontal wheel",
                isOn: $reverseHorizontal.configured(AppStorageKeys.Mouse.reverseHorizontal))
            Text("Trackpad, Magic Mouse, momentum, and Control-scroll events stay unchanged.")
                .settingsCaption()
        }
        Section("Pointer focus") {
            Toggle(
                "Focus follows pointer",
                isOn: $focusFollowsPointer.configured(
                    AppStorageKeys.Mouse.focusFollowsPointer))
            if focusFollowsPointer {
                LabeledContent("Settle delay") {
                    Picker(
                        "", selection: $focusDelay.configured(AppStorageKeys.Mouse.focusDelay)
                    ) {
                        Text("150 ms").tag(150)
                        Text("300 ms").tag(300)
                        Text("500 ms").tag(500)
                        Text("750 ms").tag(750)
                        Text("1 second").tag(1_000)
                    }
                    .labelsHidden()
                }
            }
            Text("Focus waits while you drag or hold Command, Shift, Option, or Control.")
                .settingsCaption()
        }
    }

    @ViewBuilder private var buttonSections: some View {
        Section("Navigation") {
            Toggle(
                "Use side buttons for Back and Forward",
                isOn: $sideNavigation.configured(AppStorageKeys.Mouse.sideNavigation))
            Text("Automatic keeps the standard actions above. Any explicit mapping wins.")
                .settingsCaption()
        }
        Section("Extra buttons") {
            buttonPicker(
                "Button 4", selection: $button4Action, key: AppStorageKeys.Mouse.button4Action)
            buttonPicker(
                "Button 5", selection: $button5Action, key: AppStorageKeys.Mouse.button5Action)
            buttonPicker(
                "Button 6", selection: $button6Action, key: AppStorageKeys.Mouse.button6Action)
            buttonPicker(
                "Button 7", selection: $button7Action, key: AppStorageKeys.Mouse.button7Action)
            buttonPicker(
                "Button 8", selection: $button8Action, key: AppStorageKeys.Mouse.button8Action)
            Text("Middle click sends a standard middle-button press at the pointer.")
                .settingsCaption()
        }
    }

    @ViewBuilder private var appSections: some View {
        Section("Leave apps unchanged") {
            EdithTextField(
                placeholder: "com.example.game, com.example.design",
                text: $excludedApps.configured(AppStorageKeys.Mouse.excludedApps))
            Text(
                "Enter bundle identifiers separated by commas. Wheel, focus, and button handling all stand down in these apps."
            )
            .settingsCaption()
        }
    }

    private var scrollStepBinding: Binding<Double> {
        Binding(
            get: { Double(scrollStep) },
            set: {
                $scrollStep.configured(AppStorageKeys.Mouse.scrollStep).wrappedValue = Int($0)
            })
    }

    private func buttonPicker(
        _ title: String, selection: Binding<String>, key: String
    ) -> some View {
        Picker(title, selection: selection.configured(key)) {
            ForEach(MouseButtonAction.allCases) { action in
                Text(action.title).tag(action.rawValue)
            }
        }
    }
}
