import AppKit
import Combine
import EdithKit
import SwiftUI

struct OnboardingView: View {
    private enum Step: Int, CaseIterable {
        case welcome
        case restore
        case picks
        case permissions
        case ready
        case provisioning
    }

    let onFinish: () -> Void
    private let baselineGrantedPermissions: [ExtensionPermission: Bool]
    @State private var cloudBackupFound = false
    @State private var cloudChecked = false
    @State private var cloudChecking = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var transitionDirection = 1.0
    @State private var selectedIDs = OnboardingFlow.initialSelectedIDs
    @State private var icloudBackup = OnboardingFlow.initialICloudBackup
    @State private var showsAllExtensions = false
    @State private var grantedPermissions: [ExtensionPermission: Bool]
    @State private var permissionItems: [OnboardingPermission] = []

    init(onFinish: @escaping () -> Void) {
        let baselineGrantedPermissions = OnboardingFlow.grantedPermissions()
        self.onFinish = onFinish
        self.baselineGrantedPermissions = baselineGrantedPermissions
        _grantedPermissions = State(initialValue: baselineGrantedPermissions)
    }

    private var dark: Bool { colorScheme == .dark }
    private var glide: Animation {
        Motion.animation(Motion.glide, reduceMotion: reduceMotion)
    }

    var body: some View {
        VStack(spacing: UIScale.pt(0)) {
            ZStack {
                currentStep
                    .id(step)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading)
                                .combined(with: .opacity),
                            removal: .move(edge: transitionDirection > 0 ? .leading : .trailing)
                                .combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            stepIndicator
                .padding(.vertical, UIScale.pt(12))
            Divider()
                .overlay(DashSkin.line(dark))
            footer
                .frame(height: UIScale.pt(58))
        }
        .frame(width: UIScale.pt(620), height: UIScale.pt(560))
        .background(DashSkin.paper(dark))
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            guard step == .permissions else { return }
            refreshPermissions()
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: IPC.Name.permissionsRefreshed)
        ) { _ in
            guard step == .permissions else { return }
            grantedPermissions = OnboardingFlow.grantedPermissions()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            guard step == .permissions else { return }
            refreshPermissions()
        }
    }

    @ViewBuilder
    private var currentStep: some View {
        switch step {
        case .welcome:
            welcomeStep
        case .restore:
            restoreStep
        case .picks:
            picksStep
        case .permissions:
            permissionsStep
        case .ready:
            readyStep
        case .provisioning:
            provisioningStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: UIScale.pt(0)) {
            Spacer(minLength: 48)
            appIcon
                .frame(width: UIScale.pt(92), height: UIScale.pt(92))
                .shadow(color: .black.opacity(dark ? 0.32 : 0.16), radius: UIScale.pt(18), y: 9)
            Text("Welcome to Edith")
                .font(DashSkin.serif(36, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, UIScale.pt(24))
            Text("Your Mac's useful details and everyday tools, gathered in one place.")
                .font(.system(size: UIScale.pt(15)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .padding(.top, UIScale.pt(8))
            VStack(spacing: UIScale.pt(10)) {
                Button("Get started") { move(to: .restore, direction: 1) }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Skip setup") {
                    OnboardingFlow.skip()
                    onFinish()
                }
                .buttonStyle(.plain)
                .foregroundStyle(DashSkin.inkSoft(dark))
                .pointerCursor()
            }
            .frame(width: UIScale.pt(210))
            .padding(.top, UIScale.pt(30))
            Spacer(minLength: 28)
        }
        .padding(.horizontal, UIScale.pt(48))
    }

    private var restoreStep: some View {
        VStack(spacing: UIScale.pt(0)) {
            Spacer(minLength: 44)
            ZStack {
                Circle()
                    .fill(brandAccent.opacity(0.13))
                    .frame(width: UIScale.pt(106), height: UIScale.pt(106))
                Image(systemName: restoreSymbol)
                    .font(.system(size: UIScale.pt(40), weight: .medium))
                    .foregroundStyle(brandAccent)
            }
            Text(restoreTitle)
                .font(DashSkin.serif(34, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, UIScale.pt(22))
            Text(restoreDetail)
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .multilineTextAlignment(.center)
                .padding(.top, UIScale.pt(7))
            VStack(spacing: UIScale.pt(10)) {
                if cloudChecked {
                    Button("Continue") { move(to: .picks, direction: 1) }
                        .buttonStyle(OnboardingPrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(cloudChecking ? "Checking iCloud…" : "Check for a backup") {
                        checkForCloudBackup()
                    }
                    .buttonStyle(OnboardingPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(cloudChecking)
                    Button("Start fresh") { move(to: .picks, direction: 1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .pointerCursor()
                }
            }
            .frame(width: UIScale.pt(230))
            .padding(.top, UIScale.pt(26))
            if !cloudChecked {
                Text("macOS will ask permission to read Edith's folder in iCloud Drive.")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .padding(.top, UIScale.pt(12))
            }
            Spacer(minLength: 28)
        }
        .padding(.horizontal, UIScale.pt(48))
    }

    private var restoreSymbol: String {
        guard cloudChecked else { return "icloud" }
        return cloudBackupFound ? "checkmark.icloud" : "icloud.slash"
    }

    private var restoreTitle: String {
        guard cloudChecked else { return "Been here before?" }
        return cloudBackupFound ? "Backup found" : "No backup found"
    }

    private var restoreDetail: String {
        guard cloudChecked else {
            return
                "If you backed up Edith to iCloud, we can bring back your extensions, settings, and usage history."
        }
        if cloudBackupFound {
            return
                "Your extensions are preselected and your settings and history will be restored once setup finishes."
        }
        return "No Edith data in iCloud Drive. You can turn on backups at the end of setup."
    }

    private func checkForCloudBackup() {
        cloudChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppData.cloudBackupExists
            let restored = found ? OnboardingFlow.cloudBackupSelection() : nil
            DispatchQueue.main.async {
                cloudBackupFound = found
                if found { icloudBackup = true }
                if let restored {
                    selectedIDs = restored
                }
                cloudChecking = false
                withAnimation(glide) { cloudChecked = true }
            }
        }
    }

    private var picksStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            stepHeading(
                "Make Edith yours",
                detail: picksDetail)
            ScrollView {
                VStack(spacing: UIScale.pt(0)) {
                    LazyVGrid(columns: gridColumns, spacing: UIScale.pt(12)) {
                        ForEach(displayedEntries) { entry in
                            ExtensionChoiceCard(
                                entry: entry, selected: selectedIDs.contains(entry.id), dark: dark
                            ) {
                                withAnimation(glide) {
                                    if selectedIDs.contains(entry.id) {
                                        selectedIDs.remove(entry.id)
                                    } else {
                                        selectedIDs.insert(entry.id)
                                    }
                                }
                            }
                        }
                    }
                    marketplaceCard
                        .padding(.top, UIScale.pt(12))
                }
                .padding(.horizontal, UIScale.pt(2))
                .padding(.bottom, UIScale.pt(4))
            }
            .scrollIndicators(.never)
        }
        .padding(.top, UIScale.pt(40))
        .padding(.horizontal, UIScale.pt(30))
    }

    private var marketplaceCard: some View {
        Button {
            withAnimation(glide) { showsAllExtensions.toggle() }
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Image(systemName: showsAllExtensions ? "sparkles.rectangle.stack" : "storefront")
                    .font(.system(size: UIScale.pt(18), weight: .medium))
                    .foregroundStyle(brandAccent)
                    .frame(width: UIScale.pt(38), height: UIScale.pt(38))
                    .background(
                        brandAccent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                    Text(showsAllExtensions ? "Back to top picks" : "Explore the marketplace")
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                    Text(marketplaceDetail)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: showsAllExtensions ? "arrow.up.left" : "arrow.down.right")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            .padding(UIScale.pt(13))
            .frame(maxWidth: .infinity, minHeight: UIScale.pt(82), alignment: .leading)
            .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(14))
                    .strokeBorder(DashSkin.lineStrong(dark), style: StrokeStyle(dash: [4, 4]))
            }
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            stepHeading(
                "A few permissions",
                detail: "Grant what you are comfortable with. You can continue either way.")
            ScrollView {
                VStack(spacing: UIScale.pt(10)) {
                    ForEach(permissionItems, id: \.permission) { item in
                        OnboardingPermissionCard(
                            item: item,
                            granted: grantedPermissions[item.permission] == true,
                            dark: dark
                        ) {
                            if let request = item.permission.grantRequest {
                                IPC.post(request)
                                refreshPermissions()
                            }
                        }
                    }
                    if OnboardingFlow.hasOptionalPermissions(selectedIDs: selectedIDs) {
                        Text(
                            "Some features ask for more access the first time you use them, with an explanation."
                        )
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .lineLimit(1)
                    }
                }
                .padding(.horizontal, UIScale.pt(2))
                .padding(.bottom, UIScale.pt(4))
            }
            .scrollIndicators(.never)
        }
        .padding(.top, UIScale.pt(40))
        .padding(.horizontal, UIScale.pt(38))
        .onAppear(perform: refreshPermissions)
    }

    private var readyStep: some View {
        VStack(spacing: UIScale.pt(0)) {
            Spacer(minLength: 44)
            ZStack {
                Circle()
                    .fill(brandAccent.opacity(0.13))
                    .frame(width: UIScale.pt(106), height: UIScale.pt(106))
                Image(systemName: "checkmark")
                    .font(.system(size: UIScale.pt(44), weight: .medium))
                    .foregroundStyle(brandAccent)
            }
            Text("You're ready")
                .font(DashSkin.serif(34, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.top, UIScale.pt(22))
            Text(readySummary)
                .font(.system(size: UIScale.pt(14)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .padding(.top, UIScale.pt(7))
            VStack(spacing: UIScale.pt(6)) {
                Toggle(
                    cloudBackupFound
                        ? "Restore my iCloud backup and keep syncing"
                        : "Back up my settings to iCloud",
                    isOn: $icloudBackup
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: UIScale.pt(12.5), weight: .medium))
                .foregroundStyle(DashSkin.ink(dark))
                .padding(.horizontal, UIScale.pt(12))
                .frame(height: UIScale.pt(38))
                .background(
                    DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(DashSkin.line(dark))
                }
                .pointerCursor()
                if cloudBackupFound {
                    Text("We found an existing Edith backup in iCloud.")
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                }
            }
            .padding(.top, UIScale.pt(18))
            HStack(spacing: UIScale.pt(14)) {
                Text(hotKeyLabel)
                    .font(DashSkin.mono(20, weight: .semibold))
                    .kerning(2)
                    .foregroundStyle(DashSkin.ink(dark))
                    .padding(.horizontal, UIScale.pt(16))
                    .padding(.vertical, UIScale.pt(10))
                    .background(
                        DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(10))
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: UIScale.pt(10)).strokeBorder(
                            DashSkin.lineStrong(dark))
                    }
                Text("opens the Edith panel")
                    .font(.system(size: UIScale.pt(13)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
            }
            .padding(.top, UIScale.pt(18))
            Button("Start using Edith", action: completeOrProvisionOnboarding)
                .buttonStyle(OnboardingPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .frame(width: UIScale.pt(210))
                .padding(.top, UIScale.pt(22))
            Spacer(minLength: 28)
        }
        .padding(.horizontal, UIScale.pt(48))
    }

    private var provisioningStep: some View {
        ToolProvisioningPanel(
            title: "Setting up your extensions", tools: selectedTools,
            continueAction: onFinish
        )
        .padding(.horizontal, UIScale.pt(32))
    }

    private var stepIndicator: some View {
        HStack(spacing: UIScale.pt(8)) {
            ForEach(Step.allCases, id: \.rawValue) { item in
                Circle()
                    .fill(item == step ? brandAccent : DashSkin.lineStrong(dark))
                    .frame(width: item == step ? 8 : 6, height: item == step ? 8 : 6)
                    .animation(glide, value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: UIScale.pt(10)) {
            if step == .restore || step == .picks || step == .permissions {
                Button("Back") { goBack() }
                    .buttonStyle(.plain)
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .pointerCursor()
            }
            Spacer()
            if step == .picks {
                Button(continueLabel, action: continueFromPicks)
                    .buttonStyle(OnboardingPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            } else if step == .permissions {
                Button("Continue", action: finishSelection)
                    .buttonStyle(OnboardingPrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, UIScale.pt(30))
    }

    private var appIcon: some View {
        Group {
            if let url = Bundle.module.url(forResource: "appicon", withExtension: "png"),
                let icon = NSImage(contentsOf: url)
            {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(brandAccent)
            }
        }
    }

    private var displayedEntries: [ExtensionRegistryEntry] {
        showsAllExtensions
            ? ExtensionRegistry.entries : ExtensionRegistry.entries.filter(\.featured)
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: UIScale.pt(12)),
            GridItem(.flexible(), spacing: UIScale.pt(12)),
        ]
    }

    private var picksDetail: String {
        if cloudBackupFound && !selectedIDs.isEmpty {
            return "We preselected the extensions from your iCloud backup. Adjust as you like."
        }
        return showsAllExtensions
            ? "Choose any extensions you want ready on day one."
            : "Start with a few favorites. You can change these anytime."
    }

    private var marketplaceDetail: String {
        if showsAllExtensions {
            return "Show System, Clipboard, Notch Shelf, and Agent Usage."
        }
        return ExtensionRegistry.entries.filter { !$0.featured }.map(\.title).joined(
            separator: ", ")
    }

    private var hotKeyLabel: String {
        SharedDefaults.store.string(forKey: "hotKeyLabel") ?? "⌥⌘E"
    }

    private var continueLabel: String {
        selectedIDs.isEmpty ? "Continue" : "Continue (\(selectedIDs.count))"
    }

    private var readySummary: String {
        let extensionCount = selectedIDs.count
        let extensionLabel = extensionCount == 1 ? "extension" : "extensions"
        let extensionSummary = "\(extensionCount) \(extensionLabel) on"
        let permissionCount = OnboardingFlow.newlyGrantedCount(
            selectedIDs: selectedIDs,
            baseline: baselineGrantedPermissions,
            current: grantedPermissions)
        guard permissionCount > 0 else { return extensionSummary }
        let permissionLabel = permissionCount == 1 ? "permission" : "permissions"
        return "\(extensionSummary), \(permissionCount) \(permissionLabel) granted"
    }

    private var selectedTools: [CLIToolSpec] {
        var seen = Set<String>()
        return ExtensionRegistry.entries
            .filter { selectedIDs.contains($0.id) }
            .flatMap(\.requiredTools)
            .filter { $0.requirement.isActive() && seen.insert($0.id).inserted }
    }

    private func stepHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title)
                .font(DashSkin.serif(27, weight: .bold))
                .foregroundStyle(DashSkin.ink(dark))
            Text(detail)
                .font(.system(size: UIScale.pt(12.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
        }
    }

    private func continueFromPicks() {
        grantedPermissions = OnboardingFlow.grantedPermissions()
        permissionItems = OnboardingFlow.missingPermissions(
            selectedIDs: selectedIDs, granted: grantedPermissions)
        if permissionItems.isEmpty {
            finishSelection()
        } else {
            move(to: .permissions, direction: 1)
            refreshPermissions()
        }
    }

    private func finishSelection() {
        grantedPermissions = OnboardingFlow.grantedPermissions()
        move(to: .ready, direction: 1)
    }

    private func completeOrProvisionOnboarding() {
        OnboardingFlow.finish(selectedIDs: selectedIDs, icloudBackup: icloudBackup)
        IPC.post(IPC.Name.settingsChanged)
        if selectedTools.isEmpty {
            onFinish()
        } else {
            move(to: .provisioning, direction: 1)
        }
    }

    private func goBack() {
        switch step {
        case .restore: move(to: .welcome, direction: -1)
        case .picks: move(to: .restore, direction: -1)
        case .permissions: move(to: .picks, direction: -1)
        default: break
        }
    }

    private func move(to nextStep: Step, direction: Double) {
        transitionDirection = direction
        withAnimation(glide) { step = nextStep }
    }

    private func refreshPermissions() {
        IPC.post(IPC.Name.requestPermissionsRefresh)
        grantedPermissions = OnboardingFlow.grantedPermissions()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard step == .permissions else { return }
            grantedPermissions = OnboardingFlow.grantedPermissions()
        }
    }
}

private struct ExtensionChoiceCard: View {
    let entry: ExtensionRegistryEntry
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(9)) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: UIScale.pt(9)) {
                    ExtensionPreview(entry: entry, dark: dark)
                        .frame(maxWidth: .infinity)
                        .frame(height: UIScale.pt(52))
                        .background(
                            selected ? brandAccent.opacity(0.1) : DashSkin.paper(dark),
                            in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
                    HStack(spacing: UIScale.pt(8)) {
                        Image(systemName: entry.symbolName)
                            .font(.system(size: UIScale.pt(12), weight: .semibold))
                            .foregroundStyle(selected ? brandAccent : DashSkin.inkSoft(dark))
                        Text(entry.title)
                            .font(.system(size: UIScale.pt(13), weight: .semibold))
                            .foregroundStyle(DashSkin.ink(dark))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: UIScale.pt(14), weight: .semibold))
                            .foregroundStyle(selected ? brandAccent : DashSkin.inkFaint(dark))
                    }
                    Text(entry.subtitle)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("\(entry.title), \(selected ? "selected" : "not selected")")
            HStack(spacing: UIScale.pt(4)) {
                Button(action: action) {
                    Text(permissionNote)
                        .font(.system(size: UIScale.pt(9.5), weight: .medium))
                        .foregroundStyle(selected ? brandAccent : DashSkin.inkFaint(dark))
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .pointerCursor()
                if !permissions.isEmpty {
                    PermissionInfoButton(permissions: permissions)
                }
            }
        }
        .padding(UIScale.pt(11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(14))
                .strokeBorder(
                    selected ? brandAccent : DashSkin.line(dark),
                    lineWidth: selected ? 1.5 : 1)
        }
    }

    private var permissionNote: String {
        let required = entry.requiredPermissions.map(\.displayName)
        let optional = entry.optionalPermissions.map(\.displayName)
        if !required.isEmpty { return "Needs \(required.joined(separator: ", "))" }
        if !optional.isEmpty { return "Optional: \(optional.joined(separator: ", "))" }
        return "No permissions needed"
    }

    private var permissions: [ExtensionPermission] {
        entry.requiredPermissions + entry.optionalPermissions
    }
}

private struct OnboardingPermissionCard: View {
    let item: OnboardingPermission
    let granted: Bool
    let dark: Bool
    let grant: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: UIScale.pt(12)) {
            Image(systemName: item.permission.symbolName)
                .font(.system(size: UIScale.pt(16), weight: .medium))
                .foregroundStyle(granted ? DashSkin.ok : brandAccent)
                .frame(width: UIScale.pt(34), height: UIScale.pt(34))
                .background(
                    (granted ? DashSkin.ok : brandAccent).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: UIScale.pt(9)))
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                HStack(spacing: UIScale.pt(7)) {
                    Text(item.permission.displayName)
                        .font(.system(size: UIScale.pt(13), weight: .semibold))
                        .foregroundStyle(DashSkin.ink(dark))
                    PermissionInfoButton(item.permission)
                    Text(item.required ? "Required" : "Optional")
                        .font(.system(size: UIScale.pt(9), weight: .semibold))
                        .foregroundStyle(item.required ? DashSkin.warn : DashSkin.inkFaint(dark))
                }
                Text(item.permission.reason)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                if let explanation = item.permission.firstUseExplanation {
                    Text(explanation)
                        .font(.system(size: UIScale.pt(10.5)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            Spacer(minLength: 12)
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.system(size: UIScale.pt(11), weight: .semibold))
                    .foregroundStyle(DashSkin.ok)
            } else if item.permission.grantRequest != nil {
                Button("Grant", action: grant)
                    .controlSize(.small)
                    .pointerCursor()
            } else {
                Text("On first use")
                    .font(.system(size: UIScale.pt(10), weight: .medium))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
        }
        .padding(UIScale.pt(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(13)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(13)).strokeBorder(DashSkin.line(dark))
        }
    }
}

private struct OnboardingPrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12.5 : 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 18 : 24)
            .frame(maxWidth: compact ? nil : .infinity)
            .frame(height: compact ? 32 : 38)
            .background(
                brandAccent.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: compact ? 8 : 10)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .pointerCursor()
    }
}
