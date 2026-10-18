import Foundation

public enum LaTeXEditorResources {
    public static var url: URL? { resource("index") }
    public static var reviewURL: URL? { resource("review") }
    private static func resource(_ name: String) -> URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: name, withExtension: "html")
        #else
        return Bundle(for: ExtensionRuntime.self).url(forResource: name, withExtension: "html")
        #endif
    }
}
