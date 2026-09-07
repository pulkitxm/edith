import Foundation

public enum WindowsSystemCommands {
    public static let serviceSeparator = "\u{1F}"

    public static func reboot() -> String {
        PowerShell.command("Restart-Computer -Force")
    }

    public static func shutdown() -> String {
        PowerShell.command("Stop-Computer -Force")
    }

    public static func listServices() -> String {
        PowerShell.command(
            "Get-CimInstance Win32_Service | Select-Object -First 200 | ForEach-Object { "
                + "[Console]::Out.WriteLine($_.Name+'\(serviceSeparator)'+$_.State"
                + "+'\(serviceSeparator)'+$_.StartMode+'\(serviceSeparator)'+$_.DisplayName) }")
    }

    public static func serviceAction(_ action: String, name: String) -> String {
        let value = PowerShell.literal(name)
        switch action {
        case "start":
            return PowerShell.command("Start-Service -Name \(value) -ErrorAction Stop")
        case "stop":
            return PowerShell.command("Stop-Service -Name \(value) -Force -ErrorAction Stop")
        case "restart":
            return PowerShell.command("Restart-Service -Name \(value) -Force -ErrorAction Stop")
        default:
            return PowerShell.command("exit 1")
        }
    }

    public static func serviceJournal(name: String, lines: Int) -> String {
        PowerShell.command(
            "Get-WinEvent -LogName System -MaxEvents \(max(1, lines * 5)) | "
                + "Where-Object Message -Like \(PowerShell.literal("*\(name)*")) | "
                + "Select-Object -First \(max(1, lines)) | Format-List TimeCreated,Id,Message")
    }

    public static func kill(pid: Int, force: Bool) -> String {
        let forceArgument = force ? " -Force" : ""
        return PowerShell.command(
            "if (Get-Process -Id \(pid) -ErrorAction SilentlyContinue) { "
                + "Stop-Process -Id \(pid)\(forceArgument) -ErrorAction Stop } "
                + "else { [Console]::Out.Write('\(ProcessCommands.goneMarker)') }")
    }
}
