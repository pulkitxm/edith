import EdithExtensionSupport
import Foundation

public enum HerdrQuinjetExecutable {
    public static func local() -> URL? {
        if let fixture = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
            let url = URL(fileURLWithPath: fixture).appendingPathComponent("bin/quinjet")
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        return CLIToolEnvironment.executable(named: "quinjet")
    }
}
