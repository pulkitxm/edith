import EdithKit
import SwiftUI

struct QuickActionsRows: View {
    @AppStorage(AppStorageKeys.Tabs.quickActionsEnabled, store: SharedDefaults.store) private
        var enabled = false
    @AppStorage(AppStorageKeys.QuickActions.appearance, store: SharedDefaults.store) private
        var appearance = true
    @AppStorage(AppStorageKeys.QuickActions.keyboardLight, store: SharedDefaults.store) private
        var keyboardLight = true
    @AppStorage(AppStorageKeys.QuickActions.emptyTrash, store: SharedDefaults.store) private
        var emptyTrash = true
    @AppStorage(AppStorageKeys.QuickActions.ejectDisks, store: SharedDefaults.store) private
        var ejectDisks = true
    @AppStorage(AppStorageKeys.QuickActions.hiddenFiles, store: SharedDefaults.store) private
        var hiddenFiles = true
    @AppStorage(AppStorageKeys.QuickActions.desktopIcons, store: SharedDefaults.store) private
        var desktopIcons = true
    @AppStorage(AppStorageKeys.QuickActions.lockScreen, store: SharedDefaults.store) private
        var lockScreen = true
    @State private var model = QuickActionsModel()
    @State private var confirmingTrash = false

    private let columns = [
        GridItem(.adaptive(minimum: UIScale.pt(180)), spacing: UIScale.pt(8))
    ]

    var body: some View {
        Group {
            Section("Actions") {
                LazyVGrid(columns: columns, spacing: UIScale.pt(8)) {
                    ForEach(visibleActions) { action in
                        actionButton(action)
                    }
                }
                if let feedback = model.errorMessage ?? model.message {
                    Label(
                        feedback,
                        systemImage: model.errorMessage == nil
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(
                        model.errorMessage == nil
                            ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                    )
                    .settingsCaption()
                }
            }

            Section("Visible in the panel") {
                Toggle(
                    "Appearance", isOn: $appearance.configured(QuickAction.appearance.visibilityKey)
                )
                Toggle(
                    "Keyboard light",
                    isOn: $keyboardLight.configured(QuickAction.keyboardLight.visibilityKey))
                Toggle(
                    "Empty Trash",
                    isOn: $emptyTrash.configured(QuickAction.emptyTrash.visibilityKey))
                Toggle(
                    "Eject disks",
                    isOn: $ejectDisks.configured(QuickAction.ejectDisks.visibilityKey))
                Toggle(
                    "Hidden files",
                    isOn: $hiddenFiles.configured(QuickAction.hiddenFiles.visibilityKey))
                Toggle(
                    "Desktop icons",
                    isOn: $desktopIcons.configured(QuickAction.desktopIcons.visibilityKey))
                Toggle(
                    "Lock screen",
                    isOn: $lockScreen.configured(QuickAction.lockScreen.visibilityKey))
                Text(
                    "Keyboard light is hidden automatically on Macs without a supported backlight."
                )
                .settingsCaption()
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
        .onAppear { model.refresh() }
        .confirmationDialog(
            "Empty Trash permanently?", isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Empty Trash", role: .destructive) { model.perform(.emptyTrash) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Items in the Trash cannot be recovered after this action.")
        }
    }

    private var visibleActions: [QuickAction] {
        QuickAction.allCases.filter { action in
            isVisible(action) && action.isAvailable(in: model.snapshot)
        }
    }

    private func actionButton(_ action: QuickAction) -> some View {
        let state = action.stateLabel(in: model.snapshot)
        let unavailable = !action.isAvailable(in: model.snapshot)
        return Button {
            request(action)
        } label: {
            HStack(spacing: UIScale.pt(8)) {
                Image(systemName: action.symbolName)
                    .frame(width: UIScale.pt(18))
                VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                    Text(action.title)
                    Text(state).settingsCaption()
                }
                Spacer(minLength: 0)
                if model.running == action {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(model.running != nil || unavailable)
    }

    private func isVisible(_ action: QuickAction) -> Bool {
        switch action {
        case .appearance: appearance
        case .keyboardLight: keyboardLight
        case .emptyTrash: emptyTrash
        case .ejectDisks: ejectDisks
        case .hiddenFiles: hiddenFiles
        case .desktopIcons: desktopIcons
        case .lockScreen: lockScreen
        }
    }

    private func request(_ action: QuickAction) {
        if action == .emptyTrash {
            confirmingTrash = true
        } else {
            model.perform(action)
        }
    }
}
