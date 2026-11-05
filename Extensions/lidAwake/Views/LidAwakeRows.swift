import Combine
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

struct LidAwakeRows: View {
    @State private var enabled = LidAwakeState.isEnabled(SharedDefaults.store)
    @State private var sessionRaw = LidAwakeState.session(SharedDefaults.store).rawValue
    @State private var batteryThreshold = LidAwakeState.batteryThreshold(SharedDefaults.store)
    @State private var active = SharedDefaults.store.bool(forKey: LidAwakeState.activeKey)
    @State private var confirmingActivation = false
    @ObservedObject var operations: LidAwakeOperationModel
    var chooseSession: (LidAwakeSession) -> Void
    @State private var restoration: LidAwakeRestorationControl

    init(operations: LidAwakeOperationModel, chooseSession: @escaping (LidAwakeSession) -> Void) {
        self.operations = operations
        self.chooseSession = chooseSession
        _restoration = State(initialValue: LidAwakeRestorationControl(operations: operations))
    }

    private var activeBinding: Binding<Bool> {
        Binding(
            get: { active },
            set: { wanted in
                if wanted {
                    confirmingActivation = true
                } else {
                    operations.perform(.off)
                }
            })
    }

    private var sessionBinding: Binding<LidAwakeSession> {
        Binding(
            get: { LidAwakeSession(rawValue: sessionRaw) ?? .indefinite },
            set: { session in
                sessionRaw = session.rawValue
                chooseSession(session)
                if active { operations.perform(.on(session)) }
            })
    }

    private var batteryBinding: Binding<Int> {
        Binding(
            get: { LidAwakeState.normalizedBatteryThreshold(batteryThreshold) },
            set: { threshold in
                batteryThreshold = threshold
                applySetting(.setBatteryThreshold(threshold))
            })
    }

    private var error: String? { operations.errorMessage ?? operations.lastSnapshot?.lastError }

    private var activeDetail: String {
        if operations.lastSnapshot?.batterySuspended == true {
            return "Paused because the battery is low. It resumes after charging."
        }
        if active, let seconds = operations.lastSnapshot?.remainingSeconds, seconds > 0 {
            let minutes = Int((seconds / 60).rounded(.up))
            return "On. Turns off in \(minutes) min."
        }
        return active
            ? "On. Your Mac keeps running when you close the lid."
            : "Off. Closing the lid sleeps the Mac, even with Keep Awake on."
    }

    var body: some View {
        Group {
            if let error {
                Section {
                    HStack(alignment: .center, spacing: UIScale.pt(12)) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                            Text("Lid Awake couldn't apply the last change")
                            Text(error).settingsCaption().fixedSize(
                                horizontal: false, vertical: true)
                        }
                        Spacer(minLength: UIScale.pt(8))
                        Button("Retry") { operations.refreshStatus() }
                            .buttonStyle(.edith(.secondary))
                    }
                }
            }
            Section {
                Toggle(isOn: activeBinding) {
                    LidAwakeRowLabel("Keep running with lid closed", detail: activeDetail)
                }
                Picker(selection: sessionBinding) {
                    ForEach(LidAwakeSession.allCases, id: \.self) { session in
                        Text(session.title).tag(session)
                    }
                } label: {
                    LidAwakeRowLabel("How long", detail: "Lid Awake turns itself off after this.")
                }
                Picker(selection: batteryBinding) {
                    Text("Off").tag(0)
                    Text("10% battery").tag(10)
                    Text("20% battery").tag(20)
                    Text("30% battery").tag(30)
                } label: {
                    LidAwakeRowLabel(
                        "Auto-pause below",
                        detail:
                            "On battery, Lid Awake pauses at this level until the Mac is charged."
                    )
                }
                Toggle(isOn: restoration.binding) {
                    LidAwakeRowLabel(
                        "Restore normal sleep when Edith quits",
                        detail: "Recommended. Turning Lid Awake off always restores it.")
                }
                if operations.applying {
                    LabeledContent {
                        SkeletonGroup { SkeletonBlock(width: 120, height: 8, corner: 4) }
                    } label: {
                        Text("Updating sleep settings").foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Applying system sleep state")
                }
            } header: {
                Text("Lid closed")
            } footer: {
                Text(
                    enabled
                        ? "The first time, macOS may ask you to approve Edith's helper in Login Items. With the lid closed the Mac still uses power and makes heat, so do not put it in a bag while this is on."
                        : "Lid Awake is turned off. Turn it on in Extensions to use these controls."
                )
                .settingsCaption()
            }
            .disabled(!enabled || operations.applying)
            Section {
                Text(
                    "The lid-awake idea was inspired by Awayke, an MIT-licensed macOS utility by daemonphantom."
                )
                .foregroundStyle(.secondary)
                Link(
                    "View Awayke on GitHub",
                    destination: URL(string: "https://github.com/daemonphantom/Awayke")!)
            } header: {
                Text("Acknowledgement")
            }
        }
        .pageTask(cancel: { operations.cancel() }) { operations.refreshStatus() }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: Notification.Name(LidAwakeNotifications.distributed))
        ) { _ in operations.refreshStatus() }
        .onReceive(operations.$lastSnapshot) { snapshot in
            guard let snapshot else { return }
            enabled = snapshot.extensionEnabled
            active = snapshot.active
            sessionRaw = snapshot.session.rawValue
            batteryThreshold = snapshot.batteryThreshold
        }
        .alert("Keep running with the lid closed?", isPresented: $confirmingActivation) {
            Button("Turn On") {
                operations.perform(.on((LidAwakeSession(rawValue: sessionRaw) ?? .indefinite)))
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                LidAwakeOperationExecution.preview(
                    for: .on((LidAwakeSession(rawValue: sessionRaw) ?? .indefinite)))?.warning
                    ?? "")
        }
        .alert(
            "Leave lid-close sleep disabled after quitting?",
            isPresented: $restoration.confirmingDisabled
        ) {
            Button("Turn Off Restoration", role: .destructive) { restoration.confirmDisable() }
            Button("Cancel", role: .cancel) { restoration.cancelDisable() }
        } message: {
            Text(LidAwakeOperationExecution.preview(for: .setRestoreOnQuit(false))?.warning ?? "")
        }
    }

    private func applySetting(_ request: LidAwakeRequest) { operations.performSilently(request) }
}

@MainActor @Observable
final class LidAwakeRestorationControl {
    var confirmingDisabled = false
    private var pending: Bool?
    private let operations: LidAwakeOperationModel

    init(operations: LidAwakeOperationModel) { self.operations = operations }

    private var enabledNow: Bool {
        operations.lastSnapshot?.extensionEnabled ?? LidAwakeState.isEnabled(SharedDefaults.store)
    }

    var binding: Binding<Bool> {
        Binding(
            get: {
                self.pending ?? self.operations.lastSnapshot?.restoreOnQuit
                    ?? LidAwakeState.restoresOnQuit(SharedDefaults.store)
            },
            set: { self.choose($0) })
    }

    func choose(_ enabled: Bool) {
        guard enabledNow, !operations.applying else {
            return
        }
        if enabled {
            apply(true)
        } else {
            confirmingDisabled = true
        }
    }

    func confirmDisable() {
        guard confirmingDisabled else { return }
        confirmingDisabled = false
        guard enabledNow, !operations.applying else {
            return
        }
        apply(false)
    }

    private func apply(_ value: Bool) {
        pending = value
        let task = operations.performSilently(.setRestoreOnQuit(value))
        Task { @MainActor [weak self] in
            await task?.value
            self?.pending = nil
        }
    }

    func cancelDisable() { confirmingDisabled = false }
}

struct LidAwakeRowLabel: View {
    let title: String
    let detail: String

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            Text(title)
            Text(detail).settingsCaption().fixedSize(horizontal: false, vertical: true)
        }
    }
}
