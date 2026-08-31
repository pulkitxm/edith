import Foundation

public enum RemoteMachinePlatform: String, Codable, Equatable, Sendable {
    case darwin
    case linux
    case windows

    public static func unixName(_ value: String) -> Self? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Darwin": .darwin
        case "Linux": .linux
        default: nil
        }
    }

    public static func windowsName(_ value: String) -> Self? {
        value.trimmingCharacters(in: .whitespacesAndNewlines) == "Windows_NT"
            ? .windows : nil
    }
}

public enum PowerShell {
    public static func command(_ script: String) -> String {
        executable(arguments: ["-NonInteractive"], script: script)
    }

    public static func standardInputCommand(byteCount: Int) -> String {
        command(
            "$b=New-Object byte[] \(max(0, byteCount));$i=[Console]::OpenStandardInput();"
                + "$o=0;while($o-lt $b.Length){$n=$i.Read($b,$o,$b.Length-$o);"
                + "if($n-le 0){break};$o+=$n};"
                + "&([ScriptBlock]::Create([Text.Encoding]::UTF8.GetString($b,0,$o)))")
    }

    public static func interactiveCommand(_ script: String, keepOpen: Bool = false) -> String {
        executable(arguments: keepOpen ? ["-NoExit"] : [], script: script)
    }

    public static func userCommand(_ script: String) -> String {
        command(
            "$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; try { "
                + "& ([ScriptBlock]::Create(" + literal(script) + ")); "
                + "$edithExitCode=$LASTEXITCODE; if ($null -ne $edithExitCode) { "
                + "exit $edithExitCode } } catch { "
                + "[Console]::Error.WriteLine($_.Exception.Message); exit 1 }")
    }

    public static func literal(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public static func invocation(_ words: [String]) -> String? {
        guard let first = words.first else { return nil }
        let invocation = "& " + ([first] + words.dropFirst()).map(literal).joined(separator: " ")
        return "$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; try { "
            + invocation + "; $edithExitCode=$LASTEXITCODE; "
            + "if ($null -ne $edithExitCode) { exit $edithExitCode } } catch { "
            + "[Console]::Error.WriteLine($_.Exception.Message); exit 1 }"
    }

    public static func decodedError(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#< CLIXML") else { return value }
        let expression = try? NSRegularExpression(
            pattern: #"<S S="Error">(.*?)</S>"#,
            options: .dotMatchesLineSeparators)
        let body = trimmed.replacingOccurrences(of: "#< CLIXML", with: "")
        let range = NSRange(body.startIndex..<body.endIndex, in: body)
        let parts = expression?.matches(in: body, range: range).compactMap { match -> String? in
            guard let found = Range(match.range(at: 1), in: body) else { return nil }
            return decodedXML(String(body[found]))
        } ?? []
        if !parts.isEmpty {
            return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed.contains("Preparing modules for first use.") ? "" : value
    }

    private static func decodedXML(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard
            let expression = try? NSRegularExpression(
                pattern: #"_x([0-9A-Fa-f]{4})_"#)
        else { return result }
        let matches = expression.matches(
            in: result, range: NSRange(result.startIndex..<result.endIndex, in: result))
        for match in matches.reversed() {
            guard let full = Range(match.range(at: 0), in: result),
                let digits = Range(match.range(at: 1), in: result),
                let value = UInt32(result[digits], radix: 16),
                let scalar = UnicodeScalar(value)
            else { continue }
            result.replaceSubrange(full, with: String(Character(scalar)))
        }
        return result
    }

    private static func executable(arguments: [String], script: String) -> String {
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        let options =
            (["-NoLogo", "-NoProfile"] + arguments
                + ["-OutputFormat", "Text", "-ExecutionPolicy", "Bypass"])
            .joined(separator: " ")
        return "powershell.exe \(options) -EncodedCommand \(data.base64EncodedString())"
    }
}
