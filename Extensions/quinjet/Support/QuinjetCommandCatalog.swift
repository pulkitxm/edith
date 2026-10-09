import EdithExtensionSupport

public enum QuinjetCommandCatalog {
    public static let descriptors =
        QuinjetOperation.allCases.map(\.descriptor)
        + QuinjetSessionOperation.allCases.map(\.descriptor)
    public static func admits(_ command: String) -> Bool {
        descriptors.contains { $0.id.rawValue == command }
    }
}
