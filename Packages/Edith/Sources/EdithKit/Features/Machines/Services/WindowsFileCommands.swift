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

    public static func makeDirectory(_ path: String) -> String {
        PowerShell.command(
            "New-Item -ItemType Directory -Path \(PowerShell.literal(path)) -Force | Out-Null")
    }

    public static func freeSpace(_ path: String) -> String {
        PowerShell.command(
            "$item=Get-Item -LiteralPath \(PowerShell.literal(path)); "
                + "$drive=Get-PSDrive -Name $item.PSDrive.Name; "
                + "[Console]::Out.Write([long]($drive.Free/1KB))")
    }

    public static func directorySize(_ path: String) -> String {
        PowerShell.command(
            "$item=Get-Item -LiteralPath \(PowerShell.literal(path)); "
                + "$bytes=if ($item.PSIsContainer) { "
                + "(Get-ChildItem -LiteralPath $item.FullName -File -Recurse -Force | "
                + "Measure-Object Length -Sum).Sum } else { $item.Length }; "
                + "[Console]::Out.Write([long]([Math]::Ceiling($bytes/1KB)))")
    }

    public static func search(path: String, query: String, limit: Int) -> String {
        PowerShell.command(
            "Get-ChildItem -LiteralPath \(PowerShell.literal(path)) -Recurse -Force | "
                + "Where-Object Name -Like \(PowerShell.literal("*\(query)*")) | "
                + "Select-Object -First \(max(1, limit)) -ExpandProperty FullName")
    }

    public static func duplicate(path: String, destination: String?) -> String {
        let source = PowerShell.literal(path)
        if let destination {
            let target = PowerShell.literal(destination)
            return PowerShell.command(
                "Copy-Item -LiteralPath \(source) -Destination \(target) -Recurse; "
                    + "[Console]::Out.Write(\(target))")
        }
        return PowerShell.command(
            "$source=Get-Item -LiteralPath \(source); $directory=$source.DirectoryName; "
                + "$extension=$source.Extension; $stem=$source.BaseName; "
                + "$target=Join-Path $directory ($stem+' copy'+$extension); $n=2; "
                + "while (Test-Path -LiteralPath $target) { "
                + "$target=Join-Path $directory ($stem+' copy '+$n+$extension); $n++ }; "
                + "Copy-Item -LiteralPath $source.FullName -Destination $target -Recurse; "
                + "[Console]::Out.Write($target)")
    }

    public static func rename(path: String, destination: String) -> String {
        PowerShell.command(
            "if (Test-Path -LiteralPath \(PowerShell.literal(destination))) { exit 17 }; "
                + "Move-Item -LiteralPath \(PowerShell.literal(path)) "
                + "-Destination \(PowerShell.literal(destination))")
    }

    public static func copy(paths: [String], directory: String) -> String {
        let sources = paths.map(PowerShell.literal).joined(separator: ",")
        return PowerShell.command(
            "@(\(sources)) | ForEach-Object { Copy-Item -LiteralPath $_ "
                + "-Destination \(PowerShell.literal(directory)) -Recurse }")
    }

    public static func move(paths: [String], directory: String) -> String {
        let sources = paths.map(PowerShell.literal).joined(separator: ",")
        return PowerShell.command(
            "@(\(sources)) | ForEach-Object { Move-Item -LiteralPath $_ "
                + "-Destination \(PowerShell.literal(directory)) }")
    }

    public static func remove(paths: [String], permanently: Bool) -> String {
        let values = paths.map(PowerShell.literal).joined(separator: ",")
        if permanently {
            return PowerShell.command(
                "@(\(values)) | ForEach-Object { Remove-Item -LiteralPath $_ -Recurse -Force }")
        }
        return PowerShell.command(
            "Add-Type -AssemblyName Microsoft.VisualBasic; @(\(values)) | ForEach-Object { "
                + "$item=Get-Item -LiteralPath $_; if ($item.PSIsContainer) { "
                + "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory("
                + "$item.FullName,'OnlyErrorDialogs','SendToRecycleBin') } else { "
                + "[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile("
                + "$item.FullName,'OnlyErrorDialogs','SendToRecycleBin') } }")
    }

    public static func transfer(
        _ items: [RemoteTransferPlanItem], moving: Bool
    ) -> String? {
        guard !items.isEmpty else { return nil }
        let statements = items.map { item in
            let source = PowerShell.literal(item.sourcePath)
            let destination = PowerShell.literal(item.destinationPath)
            let replacement =
                item.replacesExisting
                ? "if (Test-Path -LiteralPath \(destination)) { "
                    + "Remove-Item -LiteralPath \(destination) -Recurse -Force }; " : ""
            let verb = moving ? "Move-Item" : "Copy-Item"
            let recursive = moving ? "" : " -Recurse"
            return replacement + "\(verb) -LiteralPath \(source) "
                + "-Destination \(destination)\(recursive)"
        }
        return PowerShell.command(statements.joined(separator: "; "))
    }

    public static func preview(path: String, limit: Int) -> String {
        PowerShell.command(
            "$stream=[IO.File]::OpenRead(\(PowerShell.literal(path))); "
                + "$count=[int][Math]::Min($stream.Length,\(max(1, limit))); "
                + "$buffer=New-Object byte[] $count; [void]$stream.Read($buffer,0,$count); "
                + "$stream.Dispose(); $stdout=[Console]::OpenStandardOutput(); "
                + "$stdout.Write($buffer,0,$count); $stdout.Flush()")
    }
}
