import Foundation
import Testing

@Suite struct CLIWiringTests {
    static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources")

    static func swiftFiles(in target: String) -> [String] {
        let root = sources.appendingPathComponent(target)
        let names =
            FileManager.default.enumerator(atPath: root.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        return names.compactMap {
            try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
    }

    static func matches(_ pattern: String, in texts: [String]) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var found: Set<String> = []
        for text in texts {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1,
                    let captured = Range(match.range(at: 1), in: text)
                else { continue }
                found.insert(String(text[captured]))
            }
        }
        return found
    }

    static let cli = swiftFiles(in: "EdithCLI")
    static let app =
        swiftFiles(in: "Edith") + swiftFiles(in: "EdithHelper")
        + swiftFiles(in: "EdithKit")

    @Test func everyNotificationTheCLISendsIsObservedSomewhere() {
        let sent = Self.matches(
            #"(?:AppBridge|IPC)\.post\(\s*IPC\.Name\.(\w+)"#, in: Self.cli)
        let observed = Self.matches(
            #"IPC\.observe\(\s*\n?\s*IPC\.Name\.(\w+)"#, in: Self.app)
        #expect(!sent.isEmpty, "the CLI sends nothing, so this test proves nothing")
        #expect(
            sent.subtracting(observed).isEmpty,
            "the CLI posts these and nothing listens: \(sent.subtracting(observed).sorted())")
    }

    @Test func everyReplyTheCLIWaitsForIsPostedSomewhere() {
        let awaited = Self.matches(
            #"awaitReply\(\s*\n?\s*IPC\.Name\.(\w+)"#, in: Self.cli)
        let posted = Self.matches(#"IPC\.post\(\s*\n?\s*IPC\.Name\.(\w+)"#, in: Self.app)
        #expect(!awaited.isEmpty, "the CLI waits for nothing, so this test proves nothing")
        let orphans = awaited.subtracting(posted).sorted()
        #expect(orphans.isEmpty, "the CLI waits for these and nothing sends them: \(orphans)")
    }

    @Test func everyNameInTheIPCCatalogIsUsedByBothHalves() throws {
        let catalog = try String(
            contentsOf: Self.sources.appendingPathComponent("EdithKit/Core/IPC.swift"),
            encoding: .utf8)
        let declared = Self.matches(
            #"public static let (\w+) = Notification\.Name"#, in: [catalog])
        let used = Self.matches(#"IPC\.Name\.(\w+)"#, in: Self.cli + Self.app)
        #expect(!declared.isEmpty)
        #expect(
            declared.subtracting(used).isEmpty,
            "these names are declared and never used: \(declared.subtracting(used).sorted())")
    }
}
