$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not $EdithMode) { $EdithMode = 'stream' }
if (-not $EdithInterval) { $EdithInterval = 2 }

function Send-EdithRecord {
    param($Value)
    $json = $Value | ConvertTo-Json -Compress -Depth 8
    [Console]::Out.WriteLine("@EDITH@$json")
    [Console]::Out.Flush()
}

$operatingSystem = Get-CimInstance Win32_OperatingSystem
$computer = Get-CimInstance Win32_ComputerSystem
$processors = @(Get-CimInstance Win32_Processor)
$coreCount = ($processors | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
$cpuModel = ($processors | Select-Object -ExpandProperty Name -Unique) -join ', '
$virtual = $computer.Model -match 'Virtual|VMware|KVM|Hyper-V|VirtualBox'
$hello = [ordered]@{
    t = 'hello'
    v = 1
    os = $operatingSystem.Caption
    osID = 'windows'
    kernel = $operatingSystem.Version
    arch = $env:PROCESSOR_ARCHITECTURE
    host = $env:COMPUTERNAME
    cpuModel = $cpuModel
    cores = [int]$coreCount
    memTotalKB = [long]($computer.TotalPhysicalMemory / 1KB)
    virtual = [bool]$virtual
}
Send-EdithRecord $hello

$tick = 0
do {
    $started = [DateTimeOffset]::UtcNow
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object Name -eq '_Total' | Select-Object -First 1
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $system = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
    $diskRows = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object Name -ne '_Total')
    $networkRows = @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)
    $processRows = @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | Where-Object { $_.Name -notin @('_Total', 'Idle') } | Sort-Object PercentProcessorTime -Descending | Select-Object -First 30)
    $availableKB = [long]$memory.AvailableKBytes
    $totalKB = [long]($computer.TotalPhysicalMemory / 1KB)
    $usedKB = [long][Math]::Max(0, $totalKB - $availableKB)
    $diskRead = [double](($diskRows | Measure-Object -Property DiskReadBytesPersec -Sum).Sum)
    $diskWrite = [double](($diskRows | Measure-Object -Property DiskWriteBytesPersec -Sum).Sum)
    $networkReceive = [double](($networkRows | Measure-Object -Property BytesReceivedPersec -Sum).Sum)
    $networkSend = [double](($networkRows | Measure-Object -Property BytesSentPersec -Sum).Sum)
    $diskDevices = @($diskRows | ForEach-Object {
        [ordered]@{
            n = [string]$_.Name
            readBps = [double]$_.DiskReadBytesPersec
            writeBps = [double]$_.DiskWriteBytesPersec
            busy = [double][Math]::Min(100, $_.PercentDiskTime)
        }
    })
    $networkInterfaces = @($networkRows | ForEach-Object {
        [ordered]@{
            n = [string]$_.Name
            rxBps = [double]$_.BytesReceivedPersec
            txBps = [double]$_.BytesSentPersec
            virtual = [bool]($_.Name -match 'Virtual|Hyper-V|Loopback|VPN|TAP')
        }
    })
    $processes = @($processRows | ForEach-Object {
        [ordered]@{
            pid = [int]$_.IDProcess
            user = ''
            cpu = [double]$_.PercentProcessorTime
            mem = if ($totalKB -gt 0) { [double]($_.WorkingSetPrivate / 1KB / $totalKB * 100) } else { 0.0 }
            rssKB = [long]($_.WorkingSetPrivate / 1KB)
            name = [string]$_.Name
            cmd = [string]$_.Name
        }
    })
    $uptime = ([DateTime]::Now - $operatingSystem.LastBootUpTime).TotalSeconds
    $sample = [ordered]@{
        t = 'sample'
        ts = [double]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000)
        dt = [double]$EdithInterval
        cpu = [ordered]@{ total = [double]$cpu.PercentProcessorTime; steal = 0.0; cores = @() }
        mem = [ordered]@{
            totalKB = $totalKB
            availKB = $availableKB
            usedKB = $usedKB
            buffcacheKB = 0
            swapTotalKB = [long](($operatingSystem.TotalVirtualMemorySize - $operatingSystem.TotalVisibleMemorySize))
            swapUsedKB = [long](($operatingSystem.TotalVirtualMemorySize - $operatingSystem.FreeVirtualMemory) - $usedKB)
        }
        load = @()
        tasks = [ordered]@{ runnable = [int]$system.ProcessorQueueLength; total = $processRows.Count }
        uptime = [double]$uptime
        disk = [ordered]@{ devices = $diskDevices; readBps = $diskRead; writeBps = $diskWrite }
        net = [ordered]@{ ifaces = $networkInterfaces; rxBps = $networkReceive; txBps = $networkSend }
        procs = $processes
    }
    Send-EdithRecord $sample

    if (($tick % 15) -eq 0) {
        $filesystems = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            [ordered]@{
                fs = [string]$_.FileSystem
                mount = [string]$_.DeviceID + '\'
                totalKB = [long]($_.Size / 1KB)
                usedKB = [long](($_.Size - $_.FreeSpace) / 1KB)
                availKB = [long]($_.FreeSpace / 1KB)
            }
        })
        $batteryRow = Get-CimInstance Win32_Battery | Select-Object -First 1
        $battery = if ($batteryRow) {
            [ordered]@{
                percent = [int]$batteryRow.EstimatedChargeRemaining
                status = if ($batteryRow.BatteryStatus -eq 1) { 'Discharging' } else { 'Charging' }
            }
        } else { $null }
        $slow = [ordered]@{
            t = 'slow'
            disks = $filesystems
            temps = @()
            fans = @()
            platformProfile = $null
            battery = $battery
            gpu = $null
        }
        Send-EdithRecord $slow
    }

    $tick += 1
    if ($EdithMode -eq 'once') { break }
    $elapsed = ([DateTimeOffset]::UtcNow - $started).TotalSeconds
    Start-Sleep -Milliseconds ([int]([Math]::Max(0.1, $EdithInterval - $elapsed) * 1000))
} while ($true)
