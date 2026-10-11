from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys

repository = Path(__file__).resolve().parent.parent
scratch = Path(sys.argv[1]).resolve()
assert not scratch.exists()
home = Path(os.environ["HOME"]).resolve()
assert str(home) == os.environ["CFFIXED_USER_HOME"]
assert home.is_relative_to(scratch.parent)
scratch.mkdir(mode=0o700)
receipts = {}

def read(path):
    content = (repository / path).read_text()
    receipts[path] = hashlib.sha256(content.encode()).hexdigest()
    return content

def write(module, name, content):
    directory = scratch / "Sources" / module
    directory.mkdir(parents=True, exist_ok=True)
    (directory / name).write_text(content)

support = "Packages/ExtensionSupport/Sources/EdithExtensionSupport/"
for name in ["PersistentFileLease.swift", "ExtensionData.swift", "RestoredPathValidation.swift", "AppStorageKeys.swift"]:
    write("EdithExtensionSupport", name, read(support + name))
cli = read(support + "CLICommandRunner.swift")
request = cli[cli.index("public struct CLICommandRequest:"):cli.index("public enum ToolVersionProbe")]
result = cli[cli.index("public struct CLICommandResult:"):cli.index("public enum CLICommandRunnerError")]
write("EdithExtensionSupport", "CLIValues.swift", "import Foundation\n" + request + result)
write("EdithExtensionSupport", "DefaultsBoundary.swift", 'import Foundation\npublic enum SharedDefaults { public static var store: UserDefaults { fatalError("Defaults are outside this fixture") } }\n')
for owner, module in [("music", "MusicHistory"), ("downloads", "DownloadsHistory")]:
    base = f"Extensions/{owner}/"
    for path in ["Models/DownloadQueue.swift", "Models/MediaDownloadInput.swift", "Services/DownloadWorker.swift", "Services/MediaDownloadRequest.swift", f"Services/{'Music' if owner == 'music' else 'Downloads'}Storage.swift"]:
        write(module, Path(path).name, read(base + path).replace("import EdithExtensionUI\n", ""))
    youtube = read(base + "Services/YoutubeDownloader.swift")
    values = youtube[youtube.index("public enum DownloadStatus:"):youtube.index("public enum DownloadSizeParser")]
    parser_start = youtube.index("public enum DownloadSizeParser")
    parser_end = youtube.index("\n@", parser_start)
    values += youtube[parser_start:parser_end]
    progress = youtube[youtube.index("    nonisolated public static func parseProgress"):]
    association = youtube[youtube.index("    public func sourceURL(forFileNamed"):youtube.index("    public func retry(_ item:")]
    projection = "public final class YoutubeDownloader {\npublic var items: [DownloadRecord]\npublic init(records: [DownloadRecord]) { items = records }\n"
    write(module, "DownloadValues.swift", "import Foundation\n" + values + "\n" + projection + association + progress)
    client = read(base + f"Services/{'MusicDownload' if owner == 'music' else 'Downloads'}Client.swift")
    end = client.index(f"public struct {'MusicDownload' if owner == 'music' else 'Downloads'}Client:")
    error = client[client.index(f"struct {'MusicDownload' if owner == 'music' else 'Downloads'}Error:"):]
    write(module, "QueueContract.swift", client[:end] + error)
    write(module, "BoundaryAdapters.swift", read("Tests/DownloadHistory/BoundaryAdapters.swift"))
write("HistoryChild", "HistoryChild.swift", read("Tests/DownloadHistory/HistoryChild.swift"))
tests = scratch / "Tests" / "HistoryTests"
tests.mkdir(parents=True)
(tests / "DownloadHistoryTests.swift").write_text(read("Tests/DownloadHistory/DownloadHistoryTests.swift"))
(scratch / "Package.swift").write_text('''// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "DownloadHistoryFixture", platforms: [.macOS(.v14)], targets: [
    .target(name: "EdithExtensionSupport", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "MusicHistory", dependencies: ["EdithExtensionSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "DownloadsHistory", dependencies: ["EdithExtensionSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "HistoryChild", dependencies: ["MusicHistory", "DownloadsHistory", "EdithExtensionSupport"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "HistoryTests", dependencies: ["MusicHistory", "DownloadsHistory", "EdithExtensionSupport"], swiftSettings: [.swiftLanguageMode(.v5)])
])
''')
(scratch / "source-receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")
environment = os.environ.copy()
environment["HISTORY_FIXTURE_ROOT"] = str(scratch / "synthetic-source-root")
environment["HISTORY_CHILD_PACKAGE"] = str(scratch)
raise SystemExit(subprocess.run(["swift", "test", "--jobs", "1", "--package-path", str(scratch)], env=environment).returncode)
