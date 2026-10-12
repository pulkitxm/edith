import Darwin
import Foundation

public enum TerminalResources {
    public static let bundleName = "TerminalNative_GhosttyTerminal.bundle"

    public static let bundle: Bundle? = locate(from: imagePath())

    static func locate(from image: URL?, fileManager: FileManager = .default) -> Bundle? {
        guard var directory = image?.deletingLastPathComponent() else { return nil }
        for _ in 0..<5 {
            for candidate in [
                directory.appendingPathComponent("Resources/\(bundleName)", isDirectory: true),
                directory.appendingPathComponent(bundleName, isDirectory: true),
            ] where fileManager.fileExists(atPath: candidate.path) {
                if let bundle = Bundle(url: candidate) { return bundle }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func imagePath() -> URL? {
        var info = Dl_info()
        guard dladdr(#dsohandle, &info) != 0, let name = info.dli_fname else { return nil }
        return URL(fileURLWithPath: String(cString: name)).resolvingSymlinksInPath()
    }
}
