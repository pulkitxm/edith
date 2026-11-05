import Foundation

public struct AgentResumeProfile: Sendable {
    public let kind: String
    public let acceptsHandoff: Bool
    let resume: @Sendable (String) -> [String]
    let prompt: @Sendable (String) -> [String]
    let exitPattern: String
    let transcript: @Sendable (String) -> String
}

public enum AgentResume {
    public static let profiles: [AgentResumeProfile] = [
        AgentResumeProfile(
            kind: "Claude Code", acceptsHandoff: true, resume: { ["--resume", $0] },
            prompt: { [$0] }, exitPattern: "claude\\s+--resume\\s+(\\S+)",
            transcript: { claudeTranscript("~/.claude/projects/*/\($0).jsonl") }),
        AgentResumeProfile(
            kind: "Codex", acceptsHandoff: true, resume: { ["resume", $0] }, prompt: { [$0] },
            exitPattern: "codex\\s+resume\\s+(\\S+)",
            transcript: {
                "Codex keeps the transcript at ~/.codex/sessions/*/*/*/rollout-*-\($0).jsonl. Subagents are other rollout files whose first line names \($0) as parent_thread_id."
            }),
        AgentResumeProfile(
            kind: "OpenCode", acceptsHandoff: true, resume: { ["-s", $0] },
            prompt: { ["--prompt", $0] }, exitPattern: "opencode\\s+-s\\s+(\\S+)",
            transcript: {
                "Run opencode export \($0) to print the transcript as JSON, and run opencode session list to find any subagent sessions it spawned."
            }),
        AgentResumeProfile(
            kind: "Cursor Agent", acceptsHandoff: true, resume: { ["--resume=" + $0] },
            prompt: { [$0] }, exitPattern: "agent\\s+--resume=(\\S+)",
            transcript: {
                "Cursor Agent keeps the transcript at ~/.cursor/projects/*/agent-transcripts/\($0)/\($0).jsonl, with subagent transcripts in the subagents folder beside it."
            }),
        AgentResumeProfile(
            kind: "Grok", acceptsHandoff: true, resume: { ["--resume", $0] }, prompt: { [$0] },
            exitPattern: "grok\\s+--resume\\s+(\\S+)",
            transcript: {
                "Grok keeps the transcript at ~/.grok/sessions/*/\($0)/chat_history.jsonl, with the full event log in events.jsonl beside it."
            }),
        AgentResumeProfile(
            kind: "Pi", acceptsHandoff: true, resume: { ["--session", $0] }, prompt: { [$0] },
            exitPattern: "pi\\s+--session\\s+(\\S+)",
            transcript: {
                "Pi keeps its transcripts under ~/.pi/agent/sessions, in a file whose name contains \($0)."
            }),
        AgentResumeProfile(
            kind: "Gemini", acceptsHandoff: true, resume: { ["--resume", $0] },
            prompt: { ["-i", $0] }, exitPattern: "gemini\\s+--resume\\s+(\\S+)",
            transcript: {
                "Gemini keeps its transcripts under ~/.gemini/tmp/*/chats, in a file whose contents name session \($0)."
            }),
        AgentResumeProfile(
            kind: "Copilot CLI", acceptsHandoff: true, resume: { ["--resume=" + $0] },
            prompt: { ["-i", $0] }, exitPattern: "copilot\\s+--resume[= ](\\S+)",
            transcript: {
                "Copilot CLI keeps the transcript at ~/.copilot/session-state/\($0)/events.jsonl."
            }),
        AgentResumeProfile(
            kind: "Cline", acceptsHandoff: true, resume: { ["--id", $0] }, prompt: { [$0] },
            exitPattern: "cline\\s+--id\\s+(\\S+)",
            transcript: {
                "Cline keeps its transcripts under ~/.cline, in a folder named \($0)."
            }),
        AgentResumeProfile(
            kind: "Amp", acceptsHandoff: false, resume: { ["threads", "continue", $0] },
            prompt: { _ in [] }, exitPattern: "amp\\s+threads\\s+continue\\s+(\\S+)",
            transcript: { "Run amp threads markdown \($0) to print the transcript." }),
    ]

    public static func profile(for kind: String) -> AgentResumeProfile? {
        let name = HerdrKind.displayName(for: kind)
        return profiles.first { $0.kind == name }
    }

    public static func handoffTargets(from kind: String) -> [String] {
        let name = HerdrKind.displayName(for: kind)
        return profiles.filter { $0.acceptsHandoff && $0.kind != name }.map(\.kind)
    }

    public static func sessionID(
        kind: String, native: HerdrNativeSession?, exitOutput: String
    ) -> String? {
        guard let profile = profile(for: kind) else { return nil }
        if let native, HerdrKind.displayName(for: native.provider) == profile.kind,
            isSessionID(native.value)
        {
            return native.value
        }
        let range = NSRange(exitOutput.startIndex..., in: exitOutput)
        guard let expression = try? NSRegularExpression(pattern: profile.exitPattern),
            let match = expression.matches(in: exitOutput, range: range).last,
            let captured = Range(match.range(at: 1), in: exitOutput)
        else { return nil }
        let id = String(exitOutput[captured])
        return isSessionID(id) ? id : nil
    }

    static func isSessionID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$", options: .regularExpression) != nil
    }

    public static func resumeArguments(kind: String, sessionID: String) -> [String] {
        profile(for: kind)?.resume(sessionID) ?? []
    }

    public static func handoffArguments(
        from source: String, sessionID: String, to target: String, transcriptPath: String? = nil
    ) -> [String] {
        guard let origin = profile(for: source), let destination = profile(for: target) else {
            return []
        }
        return destination.prompt(
            handoffPrompt(
                agent: origin.kind, sessionID: sessionID,
                transcript: transcriptPath.map(claudeTranscript) ?? origin.transcript(sessionID)))
    }

    static func handoffPrompt(agent: String, sessionID: String, transcript: String) -> String {
        "I was running a task in \(agent) (session \(sessionID)) in this folder and you are taking it over. \(transcript) Read that transcript from start to finish before doing anything else, including every subagent, teammate, background task or workflow it spawned. Treat it as a record of earlier work, and check its claims against the current state of the code before relying on them. Then make a checklist of everything I asked for and everything still unfinished, including items the previous agent planned, was working on or left broken. Do not redo finished work or discard its uncommitted changes. Continue from where it stopped, work through the whole checklist in depth, verify each item, and only stop when every required item is done."
    }

    private static func claudeTranscript(_ path: String) -> String {
        let folder = path.hasSuffix(".jsonl") ? String(path.dropLast(6)) : path
        return "Claude Code keeps the transcript at \(path), with subagent and workflow transcripts in \(folder)/subagents."
    }
}

public enum ClaudeTranscriptCommand {
    public static let notFoundStatus: Int32 = 44

    public static func script(sessionID: String, roots: [String], destination: String?) -> String {
        let quotedID = "'" + sessionID.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var lines = [
            "id=\(quotedID); newest=''",
            "for root in \(roots.joined(separator: " ")); do for file in \"$root\"/projects/*/\"$id\".jsonl; do if [ -f \"$file\" ] && { [ -z \"$newest\" ] || [ \"$file\" -nt \"$newest\" ]; }; then newest=$file; fi; done; done",
            "[ -n \"$newest\" ] || exit \(notFoundStatus)",
        ]
        if let destination {
            lines += [
                "project=$(basename \"$(dirname \"$newest\")\")",
                "target=\(destination)/projects/$project",
                "if [ \"$target/$id.jsonl\" != \"$newest\" ]; then umask 077; mkdir -p \"$target\" && cp -f \"$newest\" \"$target/$id.jsonl\" || exit 1; if [ -d \"${newest%.jsonl}\" ]; then cp -R \"${newest%.jsonl}\" \"$target/\" || exit 1; fi; fi",
                "newest=$target/$id.jsonl",
            ]
        }
        lines.append("printf '%s' \"$newest\"")
        return lines.joined(separator: "\n")
    }
}
