import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseConnectionCreationSheet: View {
    @Bindable var model: DatabaseConnectionCreationModel
    let saved: (DatabaseConnectionDefinition) -> Void
    let cancel: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    intro
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
        .frame(minWidth: UIScale.pt(620), minHeight: UIScale.pt(680))
        .background(DashSkin.paper(dark))
        .onDisappear {
            Task { await model.discardUnsavedCredential() }
        }
    }

    private var header: some View {
        HStack(spacing: UIScale.pt(12)) {
            ZStack {
                RoundedRectangle(cornerRadius: UIScale.pt(10))
                    .fill(DashSkin.accent(dark).opacity(0.12))
                Image(systemName: "cylinder.split.1x2.fill")
                    .font(.system(size: UIScale.pt(17), weight: .semibold))
                    .foregroundStyle(DashSkin.accent(dark))
            }
            .frame(width: UIScale.pt(38), height: UIScale.pt(38))
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text("New database connection")
                    .font(.system(size: UIScale.pt(16), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                Text("Credentials stay in Keychain. The broker receives references only.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Spacer(minLength: 0)
            Button("Cancel", action: cancel)
                .buttonStyle(.edith(.borderless))
        }
        .padding(.horizontal, UIScale.pt(22))
        .padding(.vertical, UIScale.pt(16))
        .background(DashSkin.paper2(dark).opacity(0.55))
    }

    private var intro: some View {
        HStack(alignment: .top, spacing: UIScale.pt(10)) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(DashSkin.gold)
            Text("Every saved connection carries its environment and mutation policy. Test the exact details before Save becomes available.")
                .font(.system(size: UIScale.pt(11.5)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(UIScale.pt(12))
        .background(DashSkin.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: UIScale.pt(10)))
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
                        .foregroundStyle(DashSkin.ink(dark))
                        .edithFieldSurface(focused: false)
                }
            }
            field(model.databaseLabel) {
                EdithTextField(
                    placeholder: model.product == .redis || model.product == .valkey
                        ? "0" : "Optional default database",
                    text: textBinding(\.database))
            }
            if model.supportsTLS {
                Toggle("Require TLS with full certificate verification", isOn: boolBinding(\.tlsEnabled))
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
        .background(DashSkin.paper2(dark).opacity(0.55))
    }

    @ViewBuilder
    private var phaseStatus: some View {
        switch model.phase {
        case .editing:
            status("Test required", symbol: "circle.dashed", color: DashSkin.inkFaint(dark))
        case .testing:
            status("Testing through broker", symbol: "arrow.triangle.2.circlepath", color: DashSkin.accent(dark))
        case .tested(let detail):
            status(detail, symbol: "checkmark.circle.fill", color: DashSkin.ok)
        case .saving:
            status("Saving connection", symbol: "tray.and.arrow.down", color: DashSkin.accent(dark))
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
                .foregroundStyle(DashSkin.inkSoft(dark))
                .textCase(.uppercase)
                .tracking(0.4)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(UIScale.pt(14))
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(12))
                .stroke(DashSkin.line(dark), lineWidth: 1)
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
                .foregroundStyle(DashSkin.inkFaint(dark))
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

    private var environmentBinding: Binding<DatabaseEnvironmentKind> {
        Binding(get: { model.environmentKind }, set: model.selectEnvironment)
    }

    private func textBinding(_ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, String>) -> Binding<String> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }

    private func boolBinding(_ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, Bool>) -> Binding<Bool> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }

    private func enumBinding<Value>(_ keyPath: ReferenceWritableKeyPath<DatabaseConnectionCreationModel, Value>) -> Binding<Value> {
        Binding(
            get: { model[keyPath: keyPath] },
            set: {
                model[keyPath: keyPath] = $0
                model.invalidateTest()
            })
    }
}
