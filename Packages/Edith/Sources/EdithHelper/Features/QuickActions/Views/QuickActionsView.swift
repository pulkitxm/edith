import EdithKit
import SwiftUI

struct QuickActionsView: View {
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"
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
        GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
    ]

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                eyebrow("QUICK ACTIONS")
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.edith(.toolbar))
                .help("Refresh current macOS states")
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(visibleActions) { action in
                    actionButton(action)
                }
            }

            if let feedback = model.errorMessage ?? model.message {
                HStack(spacing: 6) {
                    Image(
                        systemName: model.errorMessage == nil
                            ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(feedback).lineLimit(2)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(
                    model.errorMessage == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .card()
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
        QuickAction.allCases.filter { isVisible($0) && $0.isAvailable(in: model.snapshot) }
    }

    private func actionButton(_ action: QuickAction) -> some View {
        Button {
            request(action)
        } label: {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(theme.opacity(0.12))
                    Image(systemName: action.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(action.stateLabel(in: model.snapshot))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.running == action {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.edith(.borderless))
        .disabled(model.running != nil || !action.isAvailable(in: model.snapshot))
        .help(action.descriptor.summary)
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
        switch action {
        case .emptyTrash:
            confirmingTrash = true
        case .lockScreen:
            dismissPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                model.perform(.lockScreen)
            }
        default:
            model.perform(action)
        }
    }
}
