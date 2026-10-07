import Foundation

public enum LaTeXEditorResources {
    public static var url: URL? {
        Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "LaTeXEditor")
    }

    public static var reviewURL: URL? {
        Bundle.module.url(forResource: "review", withExtension: "html", subdirectory: "LaTeXEditor")
    }
}
