import EdithDatabase
import EdithKit
import SwiftUI

private enum DatabaseConnectionEntryMode: String, CaseIterable {
    case url
    case details

    var title: String {
        switch self {
        case .url: "Connection URL"
        case .details: "Enter details"
        }
    }
}

struct DatabaseConnectionCreationSheet: View {
    @Bindable var model: DatabaseConnectionCreationModel
    let saved: (DatabaseConnectionDefinition) -> Void
    let cancel: () -> Void
    @State private var entryMode = DatabaseConnectionEntryMode.url
    @State private var revealsConnectionURL = false
    @State private var showsAdvanced = false
    @State private var submissionTask: Task<Void, Never>?
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: AppTheme(storedName: themeName))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(22)) {
                    Picker("Connection setup", selection: $entryMode) {
                        ForEach(DatabaseConnectionEntryMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: UIScale.pt(360))

                    if entryMode == .url {
                        urlSetup
                    } else {
                        detailsSetup
                    }

                    environmentSetup

                    DisclosureGroup("Advanced options", isExpanded: $showsAdvanced) {
                        advancedSetup
                            .padding(.top, UIScale.pt(14))
                    }
                    .font(.system(size: UIScale.pt(12), weight: .medium))
                    .foregroundStyle(palette.inkSoft)
                }
                .padding(UIScale.pt(24))
            }
            Divider().opacity(0.35)
            footer
        }
        .frame(
            minWidth: UIScale.pt(420), idealWidth: UIScale.pt(560),
            minHeight: UIScale.pt(480), idealHeight: UIScale.pt(640)
        )
        .background(palette.canvas)
        .interactiveDismissDisabled(isWorking)
        .onDisappear {
            submissionTask?.cancel()
            submissionTask = nil
            Task { await model.discardUnsavedCredential() }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: UIScale.pt(24), weight: .semibold))
                .foregroundStyle(palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("Add connection")
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text("Use a URL or individual fields to start.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(palette.inkFaint)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancelSubmissionAndDismiss)
                .buttonStyle(.edith(.borderless))
                .disabled(isWorking)
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(16))
        .background(palette.panel.opacity(0.68))
    }

    private var urlSetup: some View {
        formSection(
            "Paste a database URL",
            detail: "Credentials stay in Keychain and are never shown on the connection card."
        ) {
            responsivePair {
                pickerField("Database type", selection: productBinding) {
                    ForEach(model.supportedProducts, id: \.self) { product in
                        Text(product.displayName).tag(product)
                    }
                }
            } second: {
                field("Connection name") {
                    EdithTextField(
                        placeholder: "Filled from the URL",
                        text: textBinding(\.displayName))
                }
            }

            field("Connection URL", required: true) {
                HStack(spacing: UIScale.pt(8)) {
                    Group {
                        if revealsConnectionURL {
                            TextField(
                                "postgresql://user:password@host/database",
                                text: connectionURLBinding)
                        } else {
                            SecureField(
                                "postgresql://user:password@host/database",
                                text: connectionURLBinding)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(.system(size: UIScale.pt(12), design: .monospaced))
                    .foregroundStyle(palette.ink)
                    .edithFieldSurface(focused: false)
                    .onSubmit(model.applyConnectionURL)

                    Button {
                        revealsConnectionURL.toggle()
                    } label: {
                        Image(systemName: revealsConnectionURL ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.edith(.borderless))
                    .help(revealsConnectionURL ? "Hide connection URL" : "Show connection URL")
                    .accessibilityLabel(
                        revealsConnectionURL ? "Hide connection URL" : "Show connection URL")
                }
            }

            urlImportStatus
        }
    }

    private var detailsSetup: some View {
        formSection(
            "Connection details",
            detail: "Use individual fields when you do not have a connection URL."
        ) {
            responsivePair {
                pickerField("Database type", selection: productBinding) {
                    ForEach(model.supportedProducts, id: \.self) { product in
                        Text(product.displayName).tag(product)
                    }
                }
            } second: {
                field("Connection name", required: true) {
                    EdithTextField(
                        placeholder: "Analytics staging",
                        text: textBinding(\.displayName))
                }
            }
            endpointFields
            if model.usesNetwork {
                accessFields
            }
        }
    }

    private var environmentSetup: some View {
        formSection(
            "Environment",
            detail:
                "Development connections allow changes after a review. Production starts locked."
        ) {
            Picker("Environment", selection: environmentBinding) {
                ForEach(DatabaseEnvironmentKind.allCases, id: \.self) { environment in
                    Text(environment.title).tag(environment)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.environmentKind == .production {
                Label(
                    "Production data changes are disabled until you explicitly change the policy.",
                    systemImage: "lock.shield.fill"
                )
                .foregroundStyle(DashSkin.warn)
            } else {
                Label(
                    "Every data change opens a review before it runs.",
                    systemImage: "checkmark.shield.fill"
                )
                .foregroundStyle(palette.inkSoft)
            }
        }
    }

    private var advancedSetup: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(18)) {
            if entryMode == .url, model.urlImportPhase == .applied {
                formSection(
                    "Parsed details",
                    detail: "Review or adjust the endpoint and credentials extracted from the URL."
                ) {
                    endpointFields
                    if model.usesNetwork {
                        accessFields
                    }
                }
            }

            formSection(
                "Data protection",
                detail: "These policies are enforced by the shared command layer."
            ) {
                field("Environment label", required: true) {
                    EdithTextField(
                        placeholder: "Development",
                        text: textBinding(\.environmentLabel))
                }
                responsivePair {
                    pickerField("Protection", selection: enumBinding(\.environmentProtection)) {
                        ForEach(DatabaseEnvironmentProtection.allCases, id: \.self) { protection in
                            Text(protection.title).tag(protection)
                        }
                    }
                } second: {
                    pickerField("Data access", selection: enumBinding(\.readOnlyPolicy)) {
                        ForEach(DatabaseReadOnlyPolicy.allCases, id: \.self) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                }
                pickerField("Mutation policy", selection: enumBinding(\.productionPolicy)) {
                    ForEach(DatabaseProductionPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var endpointFields: some View {
        if model.usesNetwork {
            responsivePair {
                field("Host", required: true) {
                    EdithTextField(
                        placeholder: "127.0.0.1",
                        text: textBinding(\.host))
                }
            } second: {
                field("Port", required: true) {
                    EdithTextField(
                        placeholder: "Port",
                        text: textBinding(\.port),
                        alignment: .trailing)
                }
                .frame(maxWidth: UIScale.pt(150))
            }
        } else {
            field("SQLite file", required: true) {
                HStack(spacing: UIScale.pt(8)) {
                    EdithTextField(
                        placeholder: "/path/to/database.sqlite",
                        text: textBinding(\.path))
                    Button("Choose file") { model.chooseSQLiteFile() }
                        .buttonStyle(.edith(.secondary))
                }
            }
        }
    }

    private var accessFields: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            responsivePair {
                field("Username", required: model.usernameRequired) {
                    EdithTextField(
                        placeholder: model.product == .redis || model.product == .valkey
                            ? "Optional ACL username" : "Database username",
                        text: textBinding(\.username))
                }
            } second: {
                field("Password") {
                    SecureField("Optional password", text: textBinding(\.password))
                        .textFieldStyle(.plain)
                        .font(.system(size: UIScale.pt(12.5)))
                        .foregroundStyle(palette.ink)
                        .edithFieldSurface(focused: false)
                }
            }

            field(model.databaseLabel) {
                EdithTextField(
                    placeholder: model.product == .redis || model.product == .valkey
                        ? "0" : "Optional default database",
                    text: textBinding(\.database))
            }

            if model.product == .mongoDB {
                field("Authentication database", required: true) {
                    EdithTextField(
                        placeholder: "admin",
                        text: textBinding(\.authenticationDatabase))
                }
            }

            if model.supportsTLS {
                Toggle(
                    "Require TLS with full certificate verification",
                    isOn: boolBinding(\.tlsEnabled)
                )
                .toggleStyle(.switch)
                .font(.system(size: UIScale.pt(11.5), weight: .medium))
            }
        }
    }

    @ViewBuilder
    private var urlImportStatus: some View {
        switch model.urlImportPhase {
        case .editing:
            Text("The database type resolves URLs whose scheme is shared by several products.")
                .foregroundStyle(palette.inkFaint)
        case .applied:
            Label(safeEndpointSummary, systemImage: "checkmark.circle.fill")
                .foregroundStyle(DashSkin.ok)
        case .failed(let detail):
            Label(detail, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(DashSkin.danger)
        }
    }

    private var footer: some View {
        HStack(spacing: UIScale.pt(12)) {
            phaseStatus
            Spacer(minLength: UIScale.pt(12))
            Button(action: submit) {
                if isWorking {
                    SkeletonReplica(
                        model.phase == .testing ? "Testing connection" : "Saving connection"
                    ) {
                        Text(footerActionTitle)
                    }
                } else {
                    Text(footerActionTitle)
                }
            }
            .buttonStyle(.edith(.primary, tint: palette.accent))
            .keyboardShortcut(.defaultAction)
            .disabled(isWorking)
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(14))
        .background(palette.panel.opacity(0.68))
    }

    private var footerActionTitle: String {
        model.phase == .saving || model.canSave ? "Save connection" : "Test and save"
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch model.phase {
        case .editing:
            EmptyView()
        case .testing:
            SkeletonReplica("Testing connection") {
                status("Connection ready", symbol: "checkmark.circle.fill", color: DashSkin.ok)
            }
        case .tested(let detail):
            status(detail, symbol: "checkmark.circle.fill", color: DashSkin.ok)
        case .saving:
            SkeletonReplica("Saving connection") {
                status("Connection saved", symbol: "checkmark.circle.fill", color: DashSkin.ok)
            }
        case .failed(let detail):
            status(detail, symbol: "exclamationmark.triangle.fill", color: DashSkin.danger)
        case .saved:
            status("Connection saved", symbol: "checkmark.circle.fill", color: DashSkin.ok)
        }
    }

    private func status(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(color)
            .lineLimit(2)
    }

    private func formSection<Content: View>(
        _ title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                Text(title)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text(detail)
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(palette.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field<Content: View>(
        _ label: String,
        required: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(5)) {
            Text(required ? "\(label) *" : label)
                .font(.system(size: UIScale.pt(10.5), weight: .medium))
                .foregroundStyle(palette.inkFaint)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func pickerField<Value: Hashable, Content: View>(
        _ label: String,
        selection: Binding<Value>,
        @ViewBuilder content: () -> Content
    ) -> some View {
        field(label) {
            Picker(label, selection: selection, content: content)
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func responsivePair<First: View, Second: View>(
        @ViewBuilder _ first: () -> First,
        @ViewBuilder second: () -> Second
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                first()
                second()
            }
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                first()
                second()
            }
        }
    }

    private var safeEndpointSummary: String {
        if model.product == .sqlite {
            return model.path.isEmpty ? "SQLite connection details applied" : model.path
        }
        let namespace = model.database.isEmpty ? "" : " / \(model.database)"
        return "\(model.product.displayName) · \(model.host):\(model.port)\(namespace)"
    }

    private var isWorking: Bool {
        model.phase == .testing || model.phase == .saving
    }

    private func submit() {
        submissionTask?.cancel()
        let appliesPendingURL = entryMode == .url
        submissionTask = Task {
            guard
                let connection = await model.testAndSaveConnection(
                    applyPendingURL: appliesPendingURL),
                !Task.isCancelled
            else { return }
            saved(connection)
        }
    }

    private func cancelSubmissionAndDismiss() {
        submissionTask?.cancel()
        submissionTask = nil
        cancel()
    }

    private var productBinding: Binding<DatabaseProduct> {
        Binding(get: { model.product }, set: model.selectProduct)
    }

    private var connectionURLBinding: Binding<String> {
        Binding(get: { model.connectionURL }, set: model.updateConnectionURL)
    }

    private var environmentBinding: Binding<DatabaseEnvironmentKind> {
        Binding(get: { model.environmentKind }, set: model.selectEnvironment)
    }

    private func textBinding(
        _ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, String>
    ) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }

    private func boolBinding(
        _ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }

    private func enumBinding<Value>(
        _ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, Value>
    ) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }
}
