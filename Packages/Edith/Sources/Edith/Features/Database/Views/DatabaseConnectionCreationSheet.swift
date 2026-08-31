import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionCreationSheet: View {
    @Bindable var model: DatabaseConnectionCreationModel
    let saved: (DatabaseConnectionDefinition) -> Void
    let cancel: () -> Void
    @State private var revealsConnectionURL = false
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        AppTheme.accent.rawValue
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var palette: DatabaseThemePalette {
        DatabaseThemePalette(dark: dark, theme: AppTheme(storedName: themeName))
    }
    private var supportedURLProducts: String {
        model.supportedProducts.map(\.displayName).formatted(.list(type: .and))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    section("Connection URL", symbol: "link") {
                        connectionURLFields
                    }
                    section("Identity", symbol: "tag") {
                        field("Connection name", required: true) {
                            EdithTextField(
                                placeholder: "Analytics staging",
                                text: textBinding(\.displayName))
                        }
                        field("Database product", required: true) {
                            Picker("Database product", selection: productBinding) {
                                ForEach(model.supportedProducts, id: \.self) { product in
                                    Text(product.displayName).tag(product)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    section("Endpoint", symbol: "network") {
                        endpointFields
                    }
                    if model.usesNetwork {
                        section("Access", symbol: "key.horizontal") {
                            accessFields
                        }
                    }
                    section("Safety", symbol: "checkmark.shield") {
                        safetyFields
                    }
                }
                .padding(UIScale.pt(22))
            }
            Divider().opacity(0.35)
            footer
        }
        .frame(
            minWidth: UIScale.pt(480), idealWidth: UIScale.pt(620),
            minHeight: UIScale.pt(520), idealHeight: UIScale.pt(680)
        )
        .background(palette.canvas)
        .onDisappear {
            Task { await model.discardUnsavedCredential() }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .fill(palette.accent.opacity(0.12))
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            .frame(width: UIScale.pt(38), height: UIScale.pt(38))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("New database connection")
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                    .foregroundStyle(palette.ink)
                Text("Paste a full URL or enter the connection details below.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(palette.inkFaint)
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.edith(.borderless))
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(16))
        .background(palette.panel.opacity(0.55))
    }

    private var connectionURLFields: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
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
                .font(.system(size: UIScale.pt(12.5), design: .monospaced))
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
                Button("Use URL", action: model.applyConnectionURL)
                    .buttonStyle(.edith(.secondary))
                    .disabled(!model.canApplyConnectionURL)
            }
            switch model.urlImportPhase {
            case .editing:
                Text("\(supportedURLProducts) URLs are supported.")
                    .foregroundStyle(.secondary)
            case .applied:
                Label(
                    "URL applied. Review the parsed details, then test the connection.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(DashSkin.ok)
            case .failed(let detail):
                Label(detail, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(DashSkin.danger)
            }
        }
        .font(.system(size: UIScale.pt(10.5)))
    }

    @ViewBuilder
    private var endpointFields: some View {
        if model.usesNetwork {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                field("Host", required: true) {
                    EdithTextField(
                        placeholder: "127.0.0.1",
                        text: textBinding(\.host))
                }
                .frame(maxWidth: .infinity)
                field("Port", required: true) {
                    EdithTextField(
                        placeholder: "Port",
                        text: textBinding(\.port),
                        alignment: .trailing)
                }
                .frame(width: UIScale.pt(120))
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
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                field("Username", required: model.usernameRequired) {
                    EdithTextField(
                        placeholder: model.product == .redis || model.product == .valkey
                            ? "Optional ACL username" : "Database username",
                        text: textBinding(\.username))
                }
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

    private var safetyFields: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                pickerField("Environment", selection: environmentBinding) {
                    ForEach(DatabaseEnvironmentKind.allCases, id: \.self) { environment in
                        Text(environment.title).tag(environment)
                    }
                }
                field("Environment label", required: true) {
                    EdithTextField(
                        placeholder: "Development",
                        text: textBinding(\.environmentLabel))
                }
            }
            HStack(alignment: .top, spacing: UIScale.pt(12)) {
                pickerField("Protection", selection: enumBinding(\.environmentProtection)) {
                    ForEach(DatabaseEnvironmentProtection.allCases, id: \.self) { protection in
                        Text(protection.title).tag(protection)
                    }
                }
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

    private var footer: some View {
        HStack(spacing: UIScale.pt(10)) {
            phaseStatus
            Spacer(minLength: UIScale.pt(12))
            Button {
                Task { await model.testConnection() }
            } label: {
                if model.phase == .testing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Test connection")
                }
            }
            .buttonStyle(.edith(.secondary))
            .disabled(!model.canTest)
            Button {
                Task {
                    if let connection = await model.saveConnection() {
                        saved(connection)
                    }
                }
            } label: {
                if model.phase == .saving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Save connection")
                }
            }
            .buttonStyle(.edith(.primary))
            .disabled(!model.canSave)
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(14))
        .background(palette.panel.opacity(0.55))
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch model.phase {
        case .editing:
            status("Test required", symbol: "circle.dashed", color: palette.inkFaint)
        case .testing:
            status(
                "Testing connection", symbol: "arrow.triangle.2.circlepath",
                color: palette.accent)
        case .tested(let detail):
            status(detail, symbol: "checkmark.circle.fill", color: DashSkin.ok)
        case .saving:
            status("Saving connection", symbol: "tray.and.arrow.down", color: palette.accent)
        case .failed(let detail):
            status(detail, symbol: "exclamationmark.triangle.fill", color: DashSkin.danger)
        case .saved:
            status("Connection saved", symbol: "checkmark.circle.fill", color: DashSkin.ok)
        }
    }

    private func status(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: UIScale.pt(11), weight: .medium))
            .foregroundStyle(color)
            .lineLimit(2)
    }

    private func section<Content: View>(
        _ title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Label(title, systemImage: symbol)
                .font(.system(size: UIScale.pt(12), weight: .semibold))
                .foregroundStyle(palette.inkSoft)
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(palette.panel, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .stroke(palette.line, lineWidth: 1)
        }
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
