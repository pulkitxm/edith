$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not $EdithMode) { $EdithMode = 'stream' }
if (-not $EdithInterval) { $EdithInterval = 2 }
$collectorStartedAt = [DateTimeOffset]::UtcNow
$collectorLifetimeSeconds = 600
$selfProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
$transportProcess = Get-Process -Id $selfProcess.ParentProcessId -ErrorAction SilentlyContinue
$transportProcessID = $selfProcess.ParentProcessId
$transportStartedAt = $transportProcess.StartTime

function Test-EdithTransport {
    $current = Get-Process -Id $transportProcessID -ErrorAction SilentlyContinue
    return $null -ne $current -and $current.StartTime -eq $transportStartedAt
}

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
$previousSampleAt = $null
$previousNetwork = @{}
$previousProcesses = @{}
do {
    $started = [DateTimeOffset]::UtcNow
    $sampleElapsed = if ($null -eq $previousSampleAt) {
        [double]$EdithInterval
    } else {
        [Math]::Max(0.001, ($started - $previousSampleAt).TotalSeconds)
    }
    $previousSampleAt = $started
    $cpu = Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor | Where-Object Name -eq '_Total' | Select-Object -First 1
    $memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $system = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
    $diskRows = @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk | Where-Object Name -ne '_Total')
    $networkRows = @(Get-NetAdapterStatistics)
    $processRows = @(Get-Process | Where-Object Id -ne 0)
    $availableKB = [long]$memory.AvailableKBytes
    $totalKB = [long]($computer.TotalPhysicalMemory / 1KB)
    $usedKB = [long][Math]::Max(0, $totalKB - $availableKB)
    $diskRead = [double](($diskRows | Measure-Object -Property DiskReadBytesPersec -Sum).Sum)
    $diskWrite = [double](($diskRows | Measure-Object -Property DiskWriteBytesPersec -Sum).Sum)
    $diskDevices = @($diskRows | ForEach-Object {
        [ordered]@{
            n = [string]$_.Name
            readBps = [double]$_.DiskReadBytesPersec
            writeBps = [double]$_.DiskWriteBytesPersec
            busy = [double][Math]::Min(100, $_.PercentDiskTime)
        }
    })
    $networkInterfaces = @($networkRows | ForEach-Object {
        $received = [double]$_.ReceivedBytes
        $sent = [double]$_.SentBytes
        $before = $previousNetwork[$_.Name]
        $receivedRate = if ($null -eq $before) { 0.0 } else { [Math]::Max(0, ($received - $before.received) / $sampleElapsed) }
        $sentRate = if ($null -eq $before) { 0.0 } else { [Math]::Max(0, ($sent - $before.sent) / $sampleElapsed) }
        $previousNetwork[$_.Name] = @{ received = $received; sent = $sent }
        [ordered]@{
            n = [string]$_.Name
            rxBps = [double]$receivedRate
            txBps = [double]$sentRate
            virtual = [bool]($_.Name -match 'Virtual|Hyper-V|Loopback|VPN|TAP')
        }
    })
    $processes = @($processRows | ForEach-Object {
        $cpuSeconds = if ($null -eq $_.CPU) { 0.0 } else { [double]$_.CPU }
        $before = $previousProcesses[$_.Id]
        $cpuPercent = if ($null -eq $before) { 0.0 } else { [Math]::Max(0, ($cpuSeconds - $before) / $sampleElapsed * 100) }
        $previousProcesses[$_.Id] = $cpuSeconds
        [ordered]@{
            pid = [int]$_.Id
            user = ''
            cpu = [double]$cpuPercent
            mem = if ($totalKB -gt 0) { [double]($_.WorkingSet64 / 1KB / $totalKB * 100) } else { 0.0 }
            rssKB = [long]($_.WorkingSet64 / 1KB)
            name = [string]$_.ProcessName
            cmd = [string]$_.ProcessName
        }
    } | Sort-Object { $_['cpu'] } -Descending | Select-Object -First 30)
    $activeProcessIDs = @($processRows | ForEach-Object { [int]$_.Id })
    @($previousProcesses.Keys) | Where-Object { $_ -notin $activeProcessIDs } | ForEach-Object { $previousProcesses.Remove($_) }
    $networkReceive = [double](($networkInterfaces | ForEach-Object { $_['rxBps'] } | Measure-Object -Sum).Sum)
    $networkSend = [double](($networkInterfaces | ForEach-Object { $_['txBps'] } | Measure-Object -Sum).Sum)
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
            swapUsedKB = [long][Math]::Max(0, (($operatingSystem.TotalVirtualMemorySize - $operatingSystem.FreeVirtualMemory) - $usedKB))
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
    if (-not (Test-EdithTransport)) { break }
    if (([DateTimeOffset]::UtcNow - $collectorStartedAt).TotalSeconds -ge $collectorLifetimeSeconds) { break }
    $elapsed = ([DateTimeOffset]::UtcNow - $started).TotalSeconds
    Start-Sleep -Milliseconds ([int]([Math]::Max(0.1, $EdithInterval - $elapsed) * 1000))
} while ($true)
