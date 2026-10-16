import Foundation

public enum WindowsFileCommands {
    public static func home() -> String {
        PowerShell.command(
            "[Console]::Out.Write([Environment]::GetFolderPath('UserProfile'))")
    }

    public static func list(_ path: String) -> String {
        let value = PowerShell.literal(path)
        let separator = FileListing.separator
        return PowerShell.command(
            "$path=\(value); Get-ChildItem -LiteralPath $path -Force | ForEach-Object { "
                + "$kind=if ($_.PSIsContainer) {'d'} elseif ($_.Attributes -band "
                + "[IO.FileAttributes]::ReparsePoint) {'l'} else {'f'}; "
                + "$size=if ($_.PSIsContainer) {0} else {$_.Length}; "
                + "$epoch=([DateTimeOffset]$_.LastWriteTimeUtc).ToUnixTimeSeconds(); "
                + "$target=if ($_.Target) {$_.Target -join ','} else {''}; "
                + "[Console]::Out.WriteLine($kind+'\(separator)'+$size+'\(separator)'"
                + "+$epoch+'\(separator)'+$_.Attributes+'\(separator)'+$_.Name"
                + "+'\(separator)'+$target) }")
    }

}
