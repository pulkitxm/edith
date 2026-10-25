import Foundation
public enum FilePlaces {
    public static func homeDirectoryCommand(platform: RemoteMachinePlatform) -> String {
        platform == .windows
            ? PowerShell.command("[Console]::Out.Write($env:USERPROFILE)") : "printf '%s' \"$HOME\""
    }
}
