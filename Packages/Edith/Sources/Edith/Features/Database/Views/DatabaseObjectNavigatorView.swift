import AppKit
import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseObjectNavigatorView: View {
    let explorer: DatabaseObjectExplorerModel
    let connection: DatabaseConnectionSummary
    let open: (DatabaseObjectIdentifier) -> Void
    @State private var expandedGroups = Set<DatabaseObjectIdentifier>()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)
            content
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .onChange(of: explorer.groups) { _, _ in
            expandActiveGroup()
        }
        .onAppear {
            expandActiveGroup()
        }
    }

    private var header: some View {
        VStack(spacing: UIScale.pt(9)) {
            HStack {
                Text(navigatorTitle)
                    .font(.system(size: UIScale.pt(11.5), weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Button {
                    explorer.load(connection)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.edith(.borderless))
                .help("Reload database objects")
                .accessibilityLabel("Reload database objects")
            }
            TextField("Search \(navigatorTitle.lowercased())", text: searchBinding)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: UIScale.pt(11)))
        }
        .padding(.horizontal, UIScale.pt(12))
        .padding(.vertical, UIScale.pt(10))
    }

    @ViewBuilder
    private var content: some View {
        switch explorer.state {
        case .idle:
            VStack(spacing: UIScale.pt(9)) {
                ProgressView().controlSize(.small)
                Text("Loading objects")
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading where explorer.groups.isEmpty:
            VStack(spacing: UIScale.pt(9)) {
                ProgressView().controlSize(.small)
                Text("Loading objects")
                    .font(.system(size: UIScale.pt(11.5), weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where explorer.groups.isEmpty:
            VStack(spacing: UIScale.pt(10)) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try again") { explorer.load(connection) }
                    .buttonStyle(.edith(.secondary))
            }
            .padding(UIScale.pt(16))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading, .loaded, .failed:
            objectList
        }
    }

    private var objectList: some View {
        List(selection: selectionBinding) {
            ForEach(explorer.filteredGroups) { group in
                DisclosureGroup(isExpanded: expansionBinding(group)) {
                    groupContent(group)
                } label: {
                    HStack(spacing: UIScale.pt(7)) {
                        Image(systemName: groupSymbol(group.identifier.kind))
                            .foregroundStyle(.secondary)
                        Text(group.title)
                            .font(.system(size: UIScale.pt(11), weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if group.state == .loading {
                            ProgressView().controlSize(.mini)
                        } else if !group.objects.isEmpty {
                            Text(group.objects.count.formatted())
                                .font(.system(size: UIScale.pt(9.5), weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .opacity(group.isAvailable ? 1 : 0.5)
                }
                .disabled(!group.isAvailable)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay {
            if explorer.filteredGroups.isEmpty {
                Text("No matching objects")
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func groupContent(_ group: DatabaseExplorerGroup) -> some View {
        ForEach(group.objects) { object in
            HStack(spacing: UIScale.pt(7)) {
                Image(systemName: objectSymbol(object.identifier.kind))
                    .foregroundStyle(objectColor(object.identifier.kind))
                Text(object.title)
                    .font(.system(size: UIScale.pt(11)))
                    .lineLimit(1)
                Spacer(minLength: UIScale.pt(4))
                if let estimatedRows = object.estimatedRows {
                    Text(estimatedRows.formatted(.number.notation(.compactName)))
                        .font(.system(size: UIScale.pt(9.5)))
                        .foregroundStyle(.secondary)
                }
            }
            .tag(object.identifier)
            .help(objectHelp(object))
        }
        if group.state == .loaded, group.objects.isEmpty {
            Text("No tables or views")
                .font(.system(size: UIScale.pt(10.5)))
                .foregroundStyle(.secondary)
        }
        if case .failed(let message) = group.state {
            Button {
                explorer.loadGroup(group.identifier, connection: connection)
            } label: {
                Label(message, systemImage: "arrow.clockwise")
                    .font(.system(size: UIScale.pt(10.5)))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.edith(.borderless))
        }
        if group.nextContinuation != nil {
            Button("Load more objects") {
                explorer.loadGroup(group.identifier, connection: connection, appending: true)
            }
            .buttonStyle(.edith(.borderless))
            .font(.system(size: UIScale.pt(10.5), weight: .medium))
            .foregroundStyle(Color.accentColor)
        }
    }

    private var searchBinding: Binding<String> {
        Binding(get: { explorer.searchText }, set: { explorer.searchText = $0 })
    }

    private var selectionBinding: Binding<DatabaseObjectIdentifier?> {
        Binding(
            get: { explorer.selectedObject },
            set: { object in
                explorer.select(object)
                if let object { open(object) }
            })
    }

    private func expansionBinding(_ group: DatabaseExplorerGroup) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group.identifier) },
            set: { expanded in
                if expanded {
                    expandedGroups.insert(group.identifier)
                    if group.state == .idle {
                        explorer.loadGroup(group.identifier, connection: connection)
                    }
                } else {
                    expandedGroups.remove(group.identifier)
                }
            })
    }

    private func expandActiveGroup() {
        guard let selected = explorer.selectedObject,
            let group = explorer.groups.first(where: {
                selected.path.starts(with: $0.identifier.path)
            })
                ?? explorer.groups.first(where: { $0.state == .loading || !$0.objects.isEmpty })
        else { return }
        expandedGroups.insert(group.identifier)
    }

    private func objectHelp(_ object: DatabaseExplorerObject) -> String {
        var parts = [object.identifier.kind.rawValue]
        if let columns = object.columnCount {
            parts.append("\(columns.formatted()) columns")
        }
        if let rows = object.estimatedRows {
            parts.append("about \(rows.formatted()) rows")
        }
        return parts.joined(separator: ", ")
    }

    private func groupSymbol(_ kind: DatabaseObjectKind) -> String {
        switch kind {
        case .schema: "square.stack.3d.up"
        case .database, .keyspace: "cylinder"
        default: "folder"
        }
    }

    private func objectSymbol(_ kind: DatabaseObjectKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .view: "rectangle.stack"
        case .materializedView: "rectangle.stack.fill"
        case .index: "list.bullet.rectangle"
        case .collection: "doc.on.doc"
        case .keyspace: "key.horizontal"
        default: "circle.grid.2x2"
        }
    }

    private func objectColor(_ kind: DatabaseObjectKind) -> Color {
        switch kind {
        case .view, .materializedView: .secondary
        default: .accentColor
        }
    }

    private var navigatorTitle: String {
        switch connection.product.family {
        case .relational, .analytical: "Tables"
        case .keyValue: "Keys"
        case .document: "Collections"
        case .search: "Indexes"
        }
    }
}
