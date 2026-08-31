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

    private static func executable(arguments: [String], script: String) -> String {
        let data = script.data(using: .utf16LittleEndian) ?? Data()
        let options =
            (["-NoLogo", "-NoProfile"] + arguments
                + ["-OutputFormat", "Text", "-ExecutionPolicy", "Bypass"])
            .joined(separator: " ")
        return "powershell.exe \(options) -EncodedCommand \(data.base64EncodedString())"
    }
}
