import ArgumentParser
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

struct JSONCase {
    let label: String
    let arguments: [String]
    let mutatesTheMachine: Bool

    init(_ label: String, _ arguments: [String], mutatesTheMachine: Bool = false) {
        self.label = label
        self.arguments = arguments
        self.mutatesTheMachine = mutatesTheMachine
    }
}

enum JSONContract {
    static let cases: [JSONCase] = [
        JSONCase("ed version", ["version", "--json"]),
        JSONCase("ed install", ["install", "--json"], mutatesTheMachine: true),
        JSONCase("ed uninstall", ["uninstall", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed completions install", ["completions", "install", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed app actions", ["app", "actions", "--json"]),
        JSONCase("ed app clean-keys", ["app", "clean-keys", "--json"]),
        JSONCase("ed app test-notification", ["app", "test-notification", "--json"]),
        JSONCase("ed app open", ["app", "open", "--json"]),
        JSONCase("ed app quit", ["app", "quit", "--json"]),
        JSONCase("ed app check-updates", ["app", "check-updates", "--json"]),
        JSONCase("ed app updates", ["app", "updates", "--json"]),
        JSONCase("ed app relaunch", ["app", "relaunch", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed app clear-updates", ["app", "clear-updates", "--json"], mutatesTheMachine: true),
        JSONCase("ed app reveal", ["app", "reveal", "companion", "--json"]),
        JSONCase("ed app snapshot", ["app", "snapshot", "--json"]),
        JSONCase("ed clipboard ls", ["clipboard", "ls", "--json"]),
        JSONCase("ed clipboard stats", ["clipboard", "stats", "--json"]),
        JSONCase("ed clipboard get", ["clipboard", "get", "1", "--json"]),
        JSONCase("ed clipboard copy", ["clipboard", "copy", "1", "--json"]),
        JSONCase("ed clipboard pin", ["clipboard", "pin", "1", "--json"]),
        JSONCase("ed clipboard unpin", ["clipboard", "unpin", "1", "--json"]),
        JSONCase("ed clipboard rm", ["clipboard", "rm", "1", "--json"]),
        JSONCase("ed clipboard clear", ["clipboard", "clear", "--json"]),
        JSONCase("ed music ls", ["music", "ls", "--json"]),
        JSONCase("ed music rescan", ["music", "rescan", "--json"]),
        JSONCase("ed music start", ["music", "start", "nothing-at-all", "--json"]),
        JSONCase("ed music seek", ["music", "seek", "0.5", "--json"]),
        JSONCase("ed music shuffle", ["music", "shuffle", "--json"]),
        JSONCase("ed music repeat", ["music", "repeat", "--json"]),
        JSONCase("ed music mkdir", ["music", "mkdir", "Chill", "--json"], mutatesTheMachine: true),
        JSONCase("ed music mv", ["music", "mv", "nothing-at-all", "Chill", "--json"]),
        JSONCase("ed music rename", ["music", "rename", "nothing-at-all", "New", "--json"]),
        JSONCase("ed music rm", ["music", "rm", "nothing-at-all", "--json"]),
        JSONCase("ed tools ls", ["tools", "ls", "--json"]),
        JSONCase("ed tools install", ["tools", "install", "yt-dlp", "--json"]),
        JSONCase(
            "ed machines broadcast",
            ["machines", "broadcast", "--json", "--only", "nowhere-at-all", "--", "true"]),
        JSONCase("ed apps ls", ["apps", "ls", "--json"]),
        JSONCase("ed apps quit", ["apps", "quit", "--all", "--json"]),
        JSONCase("ed download ls", ["download", "ls", "--json"]),
        JSONCase(
            "ed download add", ["download", "add", "https://youtu.be/x", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed download retry", ["download", "retry", "--all", "--json"]),
        JSONCase("ed download rm", ["download", "rm", "1", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed download clear", ["download", "clear", "--json"], mutatesTheMachine: true),
        JSONCase("ed download tool", ["download", "tool", "--json"]),
        JSONCase("ed download cancel", ["download", "cancel", "--json"], mutatesTheMachine: true),
        JSONCase("ed color ls", ["color", "ls", "--json"]),
        JSONCase("ed color clear", ["color", "clear", "--json"]),
        JSONCase("ed shelf ls", ["shelf", "ls", "--json"]),
        JSONCase("ed shelf path", ["shelf", "path", "1", "--json"]),
        JSONCase("ed shelf add", ["shelf", "add", "/etc/hosts", "--json"]),
        JSONCase("ed shelf rm", ["shelf", "rm", "1", "--json"]),
        JSONCase("ed shelf clear", ["shelf", "clear", "--json"]),
        JSONCase("ed companion status", ["companion", "status", "--json"]),
        JSONCase("ed companion hosts", ["companion", "hosts", "--json"]),
        JSONCase(
            "ed companion deploy", ["companion", "deploy", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion stack status", ["companion", "stack", "status", "--json"]),
        JSONCase(
            "ed companion stack up", ["companion", "stack", "up", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion stack down", ["companion", "stack", "down", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion stack restart", ["companion", "stack", "restart", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion stack logs", ["companion", "stack", "logs", "--json"]),
        JSONCase("ed companion stack env", ["companion", "stack", "env", "--json"]),
        JSONCase("ed companion doctor", ["companion", "doctor", "--json"]),
        JSONCase(
            "ed companion export", ["companion", "export", "/tmp/ed-export-test", "--json"]),
        JSONCase(
            "ed companion import", ["companion", "import", "/tmp/ed-export-test", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion erase",
            ["companion", "erase", "00000000-0000-0000-0000-000000000000", "--yes", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion wipe", ["companion", "wipe", "--yes", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion search", ["companion", "search", "warden", "--json"]),
        JSONCase(
            "ed companion index", ["companion", "index", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion episodes", ["companion", "episodes", "--json"]),
        JSONCase(
            "ed companion sync", ["companion", "sync", "github", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion observations", ["companion", "observations", "--json"]),
        JSONCase(
            "ed companion reflect", ["companion", "reflect", "--json"], mutatesTheMachine: true),
        JSONCase("ed companion beliefs", ["companion", "beliefs", "--json"]),
        JSONCase("ed companion ask", ["companion", "ask", "what happened", "--json"]),
        JSONCase(
            "ed companion extract", ["companion", "extract", "--json"], mutatesTheMachine: true),
        JSONCase("ed companion claims", ["companion", "claims", "--json"]),
        JSONCase(
            "ed companion corroborate", ["companion", "corroborate", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion runs", ["companion", "runs", "--json"]),
        JSONCase("ed companion personas", ["companion", "personas", "--json"]),
        JSONCase("ed companion lenses", ["companion", "lenses", "--json"]),
        JSONCase(
            "ed companion council", ["companion", "council", "should i push", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion core show", ["companion", "core", "show", "--json"]),
        JSONCase(
            "ed companion core set", ["companion", "core", "set", "values", "honest", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion why", ["companion", "why", "abc", "--json"]),
        JSONCase("ed companion hypotheses ls", ["companion", "hypotheses", "ls", "--json"]),
        JSONCase(
            "ed companion hypotheses run", ["companion", "hypotheses", "run", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion predictions", ["companion", "predictions", "--json"]),
        JSONCase("ed companion commitments", ["companion", "commitments", "--json"]),
        JSONCase("ed companion discrepancies ls", ["companion", "discrepancies", "ls", "--json"]),
        JSONCase(
            "ed companion discrepancies override",
            ["companion", "discrepancies", "override", "abc", "--real", "was pairing", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion calibration", ["companion", "calibration", "--json"]),
        JSONCase(
            "ed companion inquire next", ["companion", "inquire", "next", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion inquire answer",
            ["companion", "inquire", "answer", "abc", "yes", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed companion inquire skip", ["companion", "inquire", "skip", "abc", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion inquire mute", ["companion", "inquire", "mute", "money", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion inquire ls", ["companion", "inquire", "ls", "--json"]),
        JSONCase("ed companion entities", ["companion", "entities", "--json"]),
        JSONCase("ed companion eval ls", ["companion", "eval", "ls", "--json"]),
        JSONCase(
            "ed companion eval run", ["companion", "eval", "run", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion standup record",
            ["companion", "standup", "record", "/tmp/nowhere.md", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion standup report", ["companion", "standup", "report", "--json"]),
        JSONCase("ed companion machines ls", ["companion", "machines", "ls", "--json"]),
        JSONCase(
            "ed companion machines add",
            ["companion", "machines", "add", "nowhere-at-all", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion machines probe",
            ["companion", "machines", "probe", "nowhere-at-all", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion machines plan", ["companion", "machines", "plan", "--json"]),
        JSONCase(
            "ed companion machines profile",
            ["companion", "machines", "profile", "nowhere-at-all", "cpu-only", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion baselines", ["companion", "baselines", "--json"]),
        JSONCase("ed companion connectors show", ["companion", "connectors", "show", "--json"]),
        JSONCase(
            "ed companion connectors set",
            ["companion", "connectors", "set", "--github", "gho_x", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion connectors import",
            ["companion", "connectors", "import", "music", "/tmp/nowhere.json", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion facts", ["companion", "facts", "--json"]),
        JSONCase(
            "ed companion correct", ["companion", "correct", "abc", "--retire", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion weekly", ["companion", "weekly", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed companion db migrate", ["companion", "db", "migrate", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion db reindex", ["companion", "db", "reindex", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion db rebuild-derived", ["companion", "db", "rebuild-derived", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion ingest", ["companion", "ingest", "/tmp/nowhere.md", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion chat", ["companion", "chat", "hello there", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion conversations", ["companion", "conversations", "--json"]),
        JSONCase(
            "ed companion forget", ["companion", "forget", "abc", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion episode", ["companion", "episode", "abc", "--json"]),
        JSONCase(
            "ed companion nightly", ["companion", "nightly", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed companion reason show", ["companion", "reason", "show", "--json"]),
        JSONCase(
            "ed companion reason set",
            ["companion", "reason", "set", "--model", "claude-sonnet-5", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed companion reason test", ["companion", "reason", "test", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed cleaner scan", ["cleaner", "scan", "--json"]),
        JSONCase("ed cleaner categories", ["cleaner", "categories", "--json"]),
        JSONCase("ed cleaner clean", ["cleaner", "clean", "--json"]),
        JSONCase("ed cleaner drives", ["cleaner", "drives", "--json"]),
        JSONCase("ed config ls", ["config", "ls", "--json"]),
        JSONCase("ed config get", ["config", "get", "preventSleep", "--json"]),
        JSONCase("ed config set", ["config", "set", "preventSleep", "true", "--json"]),
        JSONCase("ed config unset", ["config", "unset", "preventSleep", "--json"]),
        JSONCase("ed config describe", ["config", "describe", "preventSleep", "--json"]),
        JSONCase("ed config import", ["config", "import", "-", "--json"], mutatesTheMachine: true),
        JSONCase("ed extensions ls", ["extensions", "ls", "--json"]),
        JSONCase("ed extensions enable", ["extensions", "enable", "clipboard", "--json"]),
        JSONCase("ed extensions disable", ["extensions", "disable", "clipboard", "--json"]),
        JSONCase("ed extensions info", ["extensions", "info", "clipboard", "--json"]),
        JSONCase("ed lid-awake status", ["lid-awake", "status", "--json"]),
        JSONCase(
            "ed lid-awake on", ["lid-awake", "on", "--json"], mutatesTheMachine: true),
        JSONCase(
            "ed lid-awake off", ["lid-awake", "off", "--json"], mutatesTheMachine: true),
        JSONCase("ed lid-awake battery", ["lid-awake", "battery", "20", "--json"]),
        JSONCase(
            "ed lid-awake restore-on-quit",
            ["lid-awake", "restore-on-quit", "true", "--json"]),
        JSONCase("ed permissions ls", ["permissions", "ls", "--json"]),
        JSONCase("ed permissions request", ["permissions", "request", "calendar", "--json"]),
        JSONCase("ed permissions refresh", ["permissions", "refresh", "--json"]),
        JSONCase("ed usage limits", ["usage", "limits", "--json"]),
        JSONCase("ed usage summary", ["usage", "summary", "--json"]),
        JSONCase("ed usage daily", ["usage", "daily", "--json"]),
        JSONCase("ed usage models", ["usage", "models", "--json"]),
        JSONCase("ed usage projects", ["usage", "projects", "--json"]),
        JSONCase("ed usage sources", ["usage", "sources", "--json"]),
        JSONCase("ed usage refresh", ["usage", "refresh", "--json"]),
        JSONCase(
            "ed usage summary --machine", ["usage", "summary", "--machine", "local", "--json"]),
        JSONCase("ed usage machines ls", ["usage", "machines", "ls", "--json"]),
        JSONCase(
            "ed usage machines collect",
            ["usage", "machines", "collect", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed usage machines enable", ["usage", "machines", "enable", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed usage machines disable",
            ["usage", "machines", "disable", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed usage machines forget",
            ["usage", "machines", "forget", "nowhere-at-all", "--json"],
            mutatesTheMachine: true),
        JSONCase("ed system stats", ["system", "stats", "--json"]),
        JSONCase("ed system disks", ["system", "disks", "--json"]),
        JSONCase("ed music status", ["music", "status", "--json"]),
        JSONCase("ed music players", ["music", "players", "--json"]),
        JSONCase("ed music play", ["music", "play", "--json"]),
        JSONCase("ed music pause", ["music", "pause", "--json"]),
        JSONCase("ed music stop", ["music", "stop", "--json"]),
        JSONCase("ed music toggle", ["music", "toggle", "--json"]),
        JSONCase("ed music next", ["music", "next", "--json"]),
        JSONCase("ed music previous", ["music", "previous", "--json"]),
        JSONCase("ed music volume", ["music", "volume", "0.5", "--json"]),
        JSONCase("ed calendar ls", ["calendar", "ls", "--json"]),
        JSONCase("ed herdr ls", ["herdr", "ls", "--json"]),
        JSONCase(
            "ed herdr command", ["herdr", "command", "nowhere-at-all", "--json"]),
        JSONCase("ed machines ls", ["machines", "ls", "--json"]),
        JSONCase("ed machines show", ["machines", "show", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines add",
            ["machines", "add", "nowhere-at-all", "--host", "127.0.0.1", "--json"],
            mutatesTheMachine: true),
        JSONCase(
            "ed machines edit", ["machines", "edit", "nowhere-at-all", "--port", "22", "--json"]),
        JSONCase("ed machines rm", ["machines", "rm", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines forwards ls", ["machines", "forwards", "ls", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines forwards add",
            [
                "machines", "forwards", "add", "nowhere-at-all", "--local", "8080",
                "--remote", "80", "--json",
            ]),
        JSONCase(
            "ed machines forwards rm",
            ["machines", "forwards", "rm", "nowhere-at-all", "1", "--json"]),
        JSONCase(
            "ed machines snippets ls", ["machines", "snippets", "ls", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines snippets add",
            ["machines", "snippets", "add", "nowhere-at-all", "logs", "uptime", "--json"]),
        JSONCase(
            "ed machines snippets rm",
            ["machines", "snippets", "rm", "nowhere-at-all", "1", "--json"]),
        JSONCase("ed machines metrics", ["machines", "metrics", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines power status",
            ["machines", "power", "status", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines power reboot",
            ["machines", "power", "reboot", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines power shutdown",
            ["machines", "power", "shutdown", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines power wake", ["machines", "power", "wake", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines thermal status",
            ["machines", "thermal", "status", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines thermal set",
            ["machines", "thermal", "set", "nowhere-at-all", "balanced", "--json"]),
        JSONCase("ed machines kill", ["machines", "kill", "nowhere-at-all", "42", "--json"]),
        JSONCase(
            "ed machines services ls", ["machines", "services", "ls", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines services start",
            ["machines", "services", "start", "nowhere-at-all", "nginx.service", "--json"]),
        JSONCase(
            "ed machines services stop",
            ["machines", "services", "stop", "nowhere-at-all", "nginx.service", "--json"]),
        JSONCase(
            "ed machines services restart",
            ["machines", "services", "restart", "nowhere-at-all", "nginx.service", "--json"]),
        JSONCase(
            "ed machines files cp",
            ["machines", "files", "cp", "nowhere-at-all", "/a", "/b", "--json"]),
        JSONCase(
            "ed machines files mv",
            ["machines", "files", "mv", "nowhere-at-all", "/a", "/b", "--json"]),
        JSONCase(
            "ed machines files rename",
            ["machines", "files", "rename", "nowhere-at-all", "/a", "b", "--json"]),
        JSONCase(
            "ed machines files mkdir",
            ["machines", "files", "mkdir", "nowhere-at-all", "/a", "--json"]),
        JSONCase(
            "ed machines files rm", ["machines", "files", "rm", "nowhere-at-all", "/a", "--json"]),
        JSONCase(
            "ed machines forwards on",
            ["machines", "forwards", "on", "nowhere-at-all", "1", "--json"]),
        JSONCase(
            "ed machines forwards off",
            ["machines", "forwards", "off", "nowhere-at-all", "1", "--json"]),
        JSONCase(
            "ed machines files search",
            ["machines", "files", "search", "nowhere-at-all", "/a", "x", "--json"]),
        JSONCase(
            "ed machines files info",
            ["machines", "files", "info", "nowhere-at-all", "/a", "--json"]),
        JSONCase(
            "ed machines files duplicate",
            ["machines", "files", "duplicate", "nowhere-at-all", "/a", "--json"]),
        JSONCase(
            "ed machines docker pause",
            ["machines", "docker", "pause", "nowhere-at-all", "api", "--json"]),
        JSONCase(
            "ed machines docker unpause",
            ["machines", "docker", "unpause", "nowhere-at-all", "api", "--json"]),
        JSONCase("ed machines workspace ls", ["machines", "workspace", "ls", "--json"]),
        JSONCase("ed machines workspace panes", ["machines", "workspace", "panes", "--json"]),
        JSONCase(
            "ed machines workspace split",
            ["machines", "workspace", "split", "1", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines workspace close", ["machines", "workspace", "close", "1", "--json"]),
        JSONCase(
            "ed machines workspace point",
            ["machines", "workspace", "point", "1", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines workspace equalize", ["machines", "workspace", "equalize", "--json"]),
        JSONCase(
            "ed machines workspace use", ["machines", "workspace", "use", "nope", "--json"]),
        JSONCase(
            "ed machines workspace new",
            ["machines", "workspace", "new", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines workspace rename",
            ["machines", "workspace", "rename", "nope", "x", "--json"]),
        JSONCase("ed machines workspace rm", ["machines", "workspace", "rm", "nope", "--json"]),
        JSONCase(
            "ed machines files undo", ["machines", "files", "undo", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines files open", ["machines", "files", "open", "nowhere-at-all", "--json"]),
        JSONCase("ed machines mounts", ["machines", "mounts", "--json"]),
        JSONCase("ed machines mount", ["machines", "mount", "nowhere-at-all", "--json"]),
        JSONCase("ed machines unmount", ["machines", "unmount", "nowhere-at-all", "--json"]),
        JSONCase("ed machines connect", ["machines", "connect", "nowhere-at-all", "--json"]),
        JSONCase("ed machines disconnect", ["machines", "disconnect", "nowhere-at-all", "--json"]),
        JSONCase("ed machines services", ["machines", "services", "nowhere-at-all", "--json"]),
        JSONCase("ed machines files ls", ["machines", "files", "ls", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines files get",
            ["machines", "files", "get", "nowhere-at-all", "/etc/hosts", "--json"]),
        JSONCase(
            "ed machines files put",
            ["machines", "files", "put", "nowhere-at-all", "/etc/hosts", "/tmp/x", "--json"]),
        JSONCase(
            "ed machines docker ps", ["machines", "docker", "ps", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines docker images",
            ["machines", "docker", "images", "nowhere-at-all", "--json"]
        ),
        JSONCase(
            "ed machines docker volumes",
            ["machines", "docker", "volumes", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines docker networks",
            ["machines", "docker", "networks", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines docker df", ["machines", "docker", "df", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines docker start",
            ["machines", "docker", "start", "nowhere-at-all", "api", "--json"]),
        JSONCase(
            "ed machines docker stop",
            ["machines", "docker", "stop", "nowhere-at-all", "api", "--json"]),
        JSONCase(
            "ed machines docker restart",
            ["machines", "docker", "restart", "nowhere-at-all", "api", "--json"]),
        JSONCase(
            "ed machines docker rm",
            ["machines", "docker", "rm", "nowhere-at-all", "api", "--json"]),
        JSONCase(
            "ed machines docker rmi",
            ["machines", "docker", "rmi", "nowhere-at-all", "nginx", "--json"]),
        JSONCase(
            "ed machines docker volume-rm",
            ["machines", "docker", "volume-rm", "nowhere-at-all", "data", "--json"]),
        JSONCase(
            "ed machines docker prune",
            ["machines", "docker", "prune", "nowhere-at-all", "system", "--json"]),
        JSONCase(
            "ed machines docker compose ls",
            ["machines", "docker", "compose", "ls", "nowhere-at-all", "--json"]),
        JSONCase(
            "ed machines docker compose up",
            ["machines", "docker", "compose", "up", "nowhere-at-all", "web", "--json"]),
        JSONCase(
            "ed machines docker compose down",
            ["machines", "docker", "compose", "down", "nowhere-at-all", "web", "--json"]),
        JSONCase(
            "ed machines docker compose restart",
            ["machines", "docker", "compose", "restart", "nowhere-at-all", "web", "--json"]),
        JSONCase(
            "ed machines docker compose pull",
            ["machines", "docker", "compose", "pull", "nowhere-at-all", "web", "--json"]),
    ]
}

@Suite struct CLIJSONContractTests {
    @Test func everyCommandThatOffersJSONIsCovered() {
        let declared = Set(JSONContract.cases.map(\.label))
        var uncovered: [String] = []
        for walk in CommandCrawler.every() where walk.type.configuration.subcommands.isEmpty {
            guard CommandCrawler.optionNames(of: walk.type).contains("--json") else { continue }
            if !declared.contains(walk.label) { uncovered.append(walk.label) }
        }
        #expect(uncovered.isEmpty, "no JSON contract case for: \(uncovered)")
    }

    @Test func stdoutIsEitherOneJSONDocumentOrNothingAtAll() async {
        for probe in JSONContract.cases where !probe.mutatesTheMachine {
            let result = await CLIProbe.run(probe.arguments)
            guard !result.stdout.isEmpty else {
                #expect(
                    result.code != 0,
                    "\(probe.label) exited 0 but printed nothing on stdout")
                continue
            }
            #expect(
                (try? result.decoded()) != nil,
                "\(probe.label) printed something that is not JSON: \(result.stdout)")
            let trailing = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!trailing.contains("\n\n"), "\(probe.label) printed more than one document")
        }
    }

    @Test func diagnosticsNeverLandOnStdout() async {
        for probe in JSONContract.cases where !probe.mutatesTheMachine {
            let result = await CLIProbe.run(probe.arguments)
            #expect(
                !result.stdout.contains("error:"), "\(probe.label) put an error on stdout")
            #expect(!result.stdout.contains("hint:"), "\(probe.label) put a hint on stdout")
        }
    }

    @Test func anyFailureLeavesStdoutEmptyAndUsesADocumentedCode() async {
        let documented: Set<Int32> = [0, 1, 2, 3, 4]
        for probe in JSONContract.cases where !probe.mutatesTheMachine {
            let result = await CLIProbe.run(probe.arguments)
            #expect(
                documented.contains(result.code),
                "\(probe.label) exited \(result.code), which the guide does not document")
            guard result.code != 0 else { continue }
            #expect(result.stdout.isEmpty, "\(probe.label) failed but still printed stdout")
        }
    }

    @Test func versionReportsItselfAndWhetherTheAppIsUp() async {
        let result = await CLIProbe.run(["version", "--json"])
        #expect(result.code == 0)
        let object = try? #require(result.object)
        #expect(Set(object?.keys ?? [:].keys) == ["version", "appRunning"])
        #expect(object?["version"] as? String == edithCLIVersion)
        #expect(object?["appRunning"] as? Bool == false)
    }

    @Test func theHumanVersionAndTheJSONVersionAgree() async {
        let human = await CLIProbe.run(["version"])
        let json = await CLIProbe.run(["version", "--json"])
        #expect(human.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == edithCLIVersion)
        #expect(json.object?["version"] as? String == edithCLIVersion)
    }

    @Test func everyExtensionRowCarriesTheSameFields() async {
        let result = await CLIProbe.run(["extensions", "ls", "--json"])
        #expect(result.code == 0)
        let rows = result.array as? [[String: Any]] ?? []
        #expect(rows.count == ExtensionRegistry.entries.count)
        let expected: Set<String> = [
            "id", "title", "summary", "group", "featured", "key", "enabled",
            "requiredCapabilities", "optionalCapabilities",
            "requiredPermissions", "optionalPermissions", "missingRequiredPermissions",
            "requiredTools",
        ]
        for row in rows {
            #expect(Set(row.keys) == expected, "\(row["id"] ?? "?") has the wrong fields")
        }
    }

    @Test func theExtensionListAndTheHumanTableAgreeOnWhatIsOn() async {
        await CLIProbe.inWorld { _ in
            _ = await CLIProbe.capture(["extensions", "enable", "clipboard"])
            let json = await CLIProbe.capture(["extensions", "ls", "--json"])
            let table = await CLIProbe.capture(["extensions", "ls"])
            let rows = json.array as? [[String: Any]] ?? []
            let on = rows.filter { $0["enabled"] as? Bool == true }.compactMap {
                $0["id"] as? String
            }
            #expect(on == ["clipboard"])
            let onRows = table.stdoutLines.filter { $0.contains(" on ") }
            #expect(onRows.count == 1)
            #expect(onRows.first?.hasPrefix("clipboard") == true)
        }
    }

    @Test func enablingAnExtensionWritesTheKeyTheAppReads() async throws {
        try await CLIProbe.inWorld { world in
            let entry = try #require(ExtensionRegistry.entries.first)
            _ = await CLIProbe.capture(["extensions", "enable", entry.id, "--json"])
            #expect(world.shared.bool(forKey: entry.defaultsKey))
            _ = await CLIProbe.capture(["extensions", "disable", entry.id, "--json"])
            #expect(!world.shared.bool(forKey: entry.defaultsKey))
        }
    }

    @Test func anExtensionCanBeNamedByItsDefaultsKeyToo() async throws {
        try await CLIProbe.inWorld { _ in
            let entry = try #require(ExtensionRegistry.entries.first)
            let result = await CLIProbe.capture([
                "extensions", "info", entry.defaultsKey, "--json",
            ])
            #expect(result.code == 0)
            #expect(result.object?["id"] as? String == entry.id)
        }
    }

    @Test func permissionRowsCarryTheSameFields() async {
        let result = await CLIProbe.run(["permissions", "ls", "--json"])
        #expect(result.code == 0)
        let object = try? #require(result.object)
        #expect(Set(object?.keys ?? [:].keys) == ["appRunning", "permissions"])
        let rows = object?["permissions"] as? [[String: Any]] ?? []
        let expected: Set<String> = [
            "id", "name", "reason", "granted", "grantsOnFirstUse", "requiredBy",
            "optionalFor", "usedByEnabledExtension", "blocksEnabledExtension",
        ]
        for row in rows { #expect(Set(row.keys) == expected) }
    }

    @Test func machineRowsCarryTheSameFields() {
        let machine = Machine(name: "Builder", host: "10.0.0.9", port: 2222, username: "root")
        guard case let .object(fields) = MachineDirectory.summary(machine) else {
            Issue.record("a summary should be an object")
            return
        }
        #expect(
            Set(fields.keys) == [
                "id", "name", "host", "port", "username", "auth", "source", "sshAlias",
                "sshTarget", "wakeMACAddress", "createdAt", "controlSocket", "connected",
            ])
    }

    @Test func diskRowsCarryTheSameFields() async {
        let result = await CLIProbe.run(["system", "disks", "--json"])
        #expect(result.code == 0)
        let object = try? #require(result.object)
        #expect(
            Set(object?.keys ?? [:].keys)
                == [
                    "filesystems", "temperatures", "fans", "platformProfile", "battery", "gpu",
                ])
        let disks = object?["filesystems"] as? [[String: Any]] ?? []
        #expect(!disks.isEmpty)
        for disk in disks {
            #expect(
                Set(disk.keys) == [
                    "filesystem", "mount", "totalKB", "usedKB", "availableKB", "usedPercent",
                ])
        }
    }

    @Test func theDiskTableAndTheDiskJSONAgreeOnHowManyVolumes() async {
        let json = await CLIProbe.run(["system", "disks", "--json"])
        let table = await CLIProbe.run(["system", "disks"])
        let disks = (json.object?["filesystems"] as? [[String: Any]] ?? []).count
        #expect(table.stdoutLines.count == disks + 1)
    }
}

@Suite struct CLITableTests {
    @Test func columnsAreAlignedAndTheLastIsNotPadded() {
        let table = TextTable.render(headers: ["A", "BB"], rows: [["1", "2"], ["longer", "3"]])
        #expect(
            table == """
                A       BB
                1       2
                longer  3
                """)
    }

    @Test func anEmptyResultStillPrintsItsHeadings() {
        #expect(TextTable.render(headers: ["A", "B"], rows: []) == "A  B")
        #expect(TextTable.render(headers: [], rows: []).isEmpty)
    }

    @Test func aRowShorterThanTheHeadingsIsPaddedNotDropped() {
        let table = TextTable.render(headers: ["A", "B", "C"], rows: [["1"]])
        #expect(table.split(separator: "\n").count == 2)
        #expect(table.hasSuffix("1"))
    }

    @Test func aRowLongerThanTheHeadingsDoesNotCrash() {
        let table = TextTable.render(headers: ["A"], rows: [["1", "2", "3"]])
        #expect(table.contains("1"))
    }

    @Test func aVeryLongValueWidensItsColumnForEveryRow() {
        let long = String(repeating: "x", count: 400)
        let table = TextTable.render(headers: ["A", "B"], rows: [[long, "1"], ["y", "2"]])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[2].hasPrefix("y" + String(repeating: " ", count: 399)))
    }

    @Test func newlinesAndTabsInsideAValueNeverBreakTheLayout() {
        let table = TextTable.render(
            headers: ["A", "B"], rows: [["one\ntwo", "x"], ["tab\there", "y"]])
        #expect(table.split(separator: "\n").count == 3)
        #expect(!table.contains("\t"))
    }

    @Test func otherControlCharactersAreDroppedRatherThanPrinted() {
        let table = TextTable.render(headers: ["A"], rows: [["bell\u{7}here"]])
        #expect(!table.contains("\u{7}"))
        #expect(table.contains("bellhere"))
    }

    @Test func widthIsCountedInCharactersSoEmojiStayAligned() {
        let table = TextTable.render(headers: ["A", "B"], rows: [["ab", "1"], ["cd", "2"]])
        let lines = table.split(separator: "\n").map(String.init)
        #expect(lines[1] == "ab  1")
        #expect(lines[2] == "cd  2")
    }

    @Test func anEmojiCellDoesNotTruncateTheRestOfTheRow() {
        let table = TextTable.render(
            headers: ["A", "B"], rows: [["👍", "kept"], ["xxxx", "also"]])
        #expect(table.contains("kept"))
        #expect(table.contains("also"))
        #expect(table.contains("👍"))
    }

    @Test func trailingBlanksAreTrimmedSoRowsCopyCleanly() {
        let table = TextTable.render(headers: ["A", "B"], rows: [["1", ""]])
        #expect(table.split(separator: "\n").last == "1")
    }
}

@Suite struct CLISilenceTests {
    static func silence(
        helperRunning: Bool, extensionOn: Bool? = nil, permissionGranted: Bool? = nil
    ) -> CLIFailure {
        let defaults = UserDefaults(suiteName: "test.cli.silence")!
        defaults.removePersistentDomain(forName: "test.cli.silence")
        CLIEnvironment.sharedDefaults = defaults
        CLIEnvironment.isHelperRunning = { helperRunning }
        if let extensionOn { defaults.set(extensionOn, forKey: "tabCalendarEnabled") }
        CLIEnvironment.permissionUsages = {
            guard let permissionGranted else { return [] }
            return PermissionCatalog.usages(
                enabledKeys: [], granted: [.calendar: permissionGranted])
        }
        defer {
            defaults.removePersistentDomain(forName: "test.cli.silence")
            CLIEnvironment.reset()
        }
        return AppBridge.silence(
            "the calendar", extensionKey: "tabCalendarEnabled", permission: "calendar")
    }

    @Test func aClosedAppIsBlamedFirst() async {
        await CLIProbe.inWorld { _ in
            let failure = Self.silence(helperRunning: false, extensionOn: true)
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("Edith is not running"))
        }
    }

    @Test func anExtensionThatIsOffIsBlamedNext() async {
        await CLIProbe.inWorld { _ in
            let failure = Self.silence(helperRunning: true, extensionOn: false)
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("extension behind the calendar is off"))
            #expect(failure.hint?.contains("ed extensions ls") == true)
        }
    }

    @Test func aMissingGrantIsBlamedAfterThat() async {
        await CLIProbe.inWorld { _ in
            let failure = Self.silence(
                helperRunning: true, extensionOn: true, permissionGranted: false)
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("macOS has not granted"))
            #expect(failure.hint?.contains("ed permissions request calendar") == true)
        }
    }

    @Test func aHealthyAppThatStaysQuietIsBlamedLast() async {
        await CLIProbe.inWorld { _ in
            let failure = Self.silence(
                helperRunning: true, extensionOn: true, permissionGranted: true)
            #expect(failure.kind == .unavailable)
            #expect(failure.message.contains("did not answer"))
            #expect(failure.hint?.contains("rebuild") == true)
        }
    }

    @Test func everyDiagnosisIsUnavailableSoTheExitCodeIsStable() async {
        await CLIProbe.inWorld { _ in
            for running in [true, false] {
                for on in [true, false] {
                    let failure = Self.silence(helperRunning: running, extensionOn: on)
                    #expect(failure.kind.rawValue == ExitCodes.unavailable)
                }
            }
        }
    }

    static let silenceIsNotAnError: Set<String> = []

    @Test func everyPlaceThatWaitsOnTheAppDiagnosesItsSilence() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/EdithCLI")
        let names =
            FileManager.default.enumerator(atPath: root.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        var waiting: [String] = []
        var offenders: [String] = []
        for name in names {
            let text = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            guard text.contains("AppBridge.awaitReply") else { continue }
            waiting.append(name)
            let leaf = (name as NSString).lastPathComponent
            guard !Self.silenceIsNotAnError.contains(leaf) else { continue }
            if !text.contains("AppBridge.silence") { offenders.append(name) }
        }
        #expect(!waiting.isEmpty, "nothing waits on the app, so this test proves nothing")
        #expect(
            offenders.isEmpty,
            "these wait on the app without diagnosing its silence: \(offenders)")
    }
}
