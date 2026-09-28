import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseStructureView: View {
    let fields: [DatabaseFieldDescriptor]
    let palette: DatabaseThemePalette
    @State private var search = ""

    private var rows: [FieldRow] {
        fields.enumerated().compactMap { index, field in
            guard
                search.isEmpty || field.displayName.localizedStandardContains(search)
                    || field.typeName.localizedStandardContains(search)
            else { return nil }
            return FieldRow(id: index, field: field)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(fields.count) fields", systemImage: "list.bullet.rectangle")
                    .font(.system(size: UIScale.pt(11), weight: .medium))
                Spacer()
                TextField("Find a field or type", text: $search)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: UIScale.pt(230))
                    .accessibilityLabel("Find a field or type")
            }.padding(UIScale.pt(12)).background(palette.panel)
            Divider()
            if fields.isEmpty {
                DatabaseWorkbenchEmptyState(
                    symbol: "list.bullet.rectangle", title: "No field metadata",
                    detail:
                        "Browse an object to inspect the fields reported by its database adapter.")
            } else if rows.isEmpty {
                DatabaseWorkbenchEmptyState(
                    symbol: "magnifyingglass", title: "No matching fields",
                    detail: "Try a different field name or data type.")
            } else {
                SwiftUI.Table(rows) {
                    SwiftUI.TableColumn("Column") { row in
                        Text(row.field.displayName).font(
                            .system(size: UIScale.pt(11), design: .monospaced))
                    }.width(min: 130, ideal: 180)
                    SwiftUI.TableColumn("Type") { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.field.typeName).font(
                                .system(size: UIScale.pt(11), design: .monospaced))
                            if let values = row.field.enumValues {
                                Text("\(values.count) choices").font(.system(size: UIScale.pt(9)))
                                    .foregroundStyle(.secondary)
                                    .help(values.prefix(20).joined(separator: ", "))
                            }
                        }
                    }.width(min: 100, ideal: 150)
                    SwiftUI.TableColumn("Nullable") { Text($0.field.isNullable ? "Yes" : "No") }
                        .width(70)
                    SwiftUI.TableColumn("Default") { Text(flag($0.field.hasDefault)) }.width(70)
                    SwiftUI.TableColumn("Generated") { Text(flag($0.field.isGenerated)) }.width(80)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .accessibilityLabel("Object field structure")
            }
            HStack {
                Text("Metadata from the selected object, independent of query results.")
                    .font(.system(size: UIScale.pt(10))).foregroundStyle(palette.inkFaint)
                Spacer()
            }.padding(UIScale.pt(12)).background(palette.panel)
        }.background(palette.canvas)
    }

    private func flag(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "Unknown"
    }

    private struct FieldRow: Identifiable {
        let id: Int
        let field: DatabaseFieldDescriptor
    }
}
