import EdithDatabase
import EdithKit
import SwiftUI

struct DatabaseDocumentNode: Identifiable {
    let id: String
    let name: String
    let value: DatabaseValue

    var children: [DatabaseDocumentNode]? {
        switch value {
        case .object(let fields): Self.fields(fields, prefix: id)
        case .array(let values):
            values.enumerated().map { index, value in
                DatabaseDocumentNode(id: "\(id).\(index)", name: "[\(index)]", value: value)
            }
        default: nil
        }
    }

    static func fields(_ fields: [DatabaseObjectField], prefix: String = "root")
        -> [DatabaseDocumentNode]
    {
        fields.enumerated().map { index, field in
            DatabaseDocumentNode(id: "\(prefix).\(index)", name: field.name, value: field.value)
        }
    }
}

struct DatabaseDocumentOutline: View {
    let nodes: [DatabaseDocumentNode]
    let text: (DatabaseValue) -> String

    var body: some View {
        LazyVStack(alignment: .leading, spacing: UIScale.pt(7)) {
            OutlineGroup(nodes, children: \.children) { node in
                HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                    Text(node.name).font(.system(size: UIScale.pt(10.5), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: UIScale.pt(8))
                    Text(DatabaseGridProjection.preview(text(node.value)))
                        .font(.system(size: UIScale.pt(11), design: .monospaced))
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
