import Combine
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

struct LidAwakeRows: View {
    @State private var enabled = false
    @State private var sessionRaw = LidAwakeSession.indefinite.rawValue
    @State private var batteryThreshold = 0
    @State private var active = false
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
                applySetting(.setBatteryThreshold(threshold))
            })
    }

    var body: some View {
        Group {
            Section {
                Toggle(isOn: activeBinding) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Keep running with lid closed")
                        InfoDot(
                            "Closing the lid normally sleeps the Mac even when Keep awake is on. This turns that pathway off, so the Mac keeps running with the lid shut - no external display or charger needed."
                        )
                    }
                }
                Text(
                    "The first activation may open Login Items for one-time approval of Edith's background helper. After that, shelf toggles are silent."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Picker("Session", selection: sessionBinding) {
                    ForEach(LidAwakeSession.allCases, id: \.self) { session in
                        Text(session.title).tag(session)
                    }
                }
                Picker("Auto-pause below", selection: batteryBinding) {
                    Text("Off").tag(0)
                    Text("10% battery").tag(10)
                    Text("20% battery").tag(20)
                    Text("30% battery").tag(30)
                }
                Text(
                    "When the Mac is on battery and reaches this floor, lid awake pauses until it is charged again. Starting it manually below the floor overrides the pause for that discharge."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                Toggle(isOn: restoration.binding) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Restore normal sleep when Edith quits")
                        InfoDot(
                            "Leave this on so the Mac sleeps normally again once Edith is not running. Turning the extension off always restores it, whatever this is set to."
                        )
                    }
                }
                Text(
                    "While this is on the Mac stays awake with a closed lid, so it keeps drawing power and shedding heat. Do not put it in a bag like this."
                )
                .font(.system(size: UIScale.pt(10))).foregroundStyle(.secondary)
                if operations.applying {
                    HStack {
                        SkeletonGroup {
                            SkeletonBlock(width: 184, height: 9, corner: 4)
                        }
                    }
                    .settingsCaption()
                    .accessibilityLabel("Applying system sleep state")
                }
                if let error = operations.errorMessage ?? operations.lastSnapshot?.lastError {
                    Text(error)
                        .settingsCaption()
                        .foregroundStyle(.red)
                }
            }
            Section {
                Text(
                    "The lid-awake idea was inspired by Awayke, an MIT-licensed macOS utility by daemonphantom."
                )
                Link(
                    "View Awayke on GitHub",
                    destination: URL(string: "https://github.com/daemonphantom/Awayke")!)
            } header: {
                Text("Acknowledgement")
            }
        }
        .disabled(!enabled)
        .disabled(operations.applying)
        .opacity(enabled ? 1 : 0.5)
        .pageTask(cancel: { operations.cancel() }) { operations.refreshStatus() }
        .onReceive(operations.$lastSnapshot) { snapshot in
            guard let snapshot else { return }
            enabled = snapshot.extensionEnabled
            active = snapshot.requestedActive
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

    private func applySetting(_ request: LidAwakeRequest) { operations.perform(request) }
}

@MainActor @Observable
final class LidAwakeRestorationControl {
    var confirmingDisabled = false
    private let operations: LidAwakeOperationModel

    init(operations: LidAwakeOperationModel) { self.operations = operations }

    var binding: Binding<Bool> {
        Binding(
            get: { self.operations.lastSnapshot?.restoreOnQuit ?? true },
            set: { self.choose($0) })
    }

    func choose(_ enabled: Bool) {
        guard operations.lastSnapshot?.extensionEnabled == true, !operations.applying else {
            return
        }
        if enabled {
            operations.perform(.setRestoreOnQuit(true))
        } else {
            confirmingDisabled = true
        }
    }

    func confirmDisable() {
        guard confirmingDisabled else { return }
        confirmingDisabled = false
        guard operations.lastSnapshot?.extensionEnabled == true, !operations.applying else {
            return
        }
        operations.perform(.setRestoreOnQuit(false))
    }

    func cancelDisable() { confirmingDisabled = false }
}
