import Foundation

public enum WindowsMachineControlCommands {
    public static let statusInput = Data(
        (audioSupport
            + """
            [Console]::Out.WriteLine('EDITH_CONTROL_PLATFORM=windows')
            $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $battery) {
                $level = [Math]::Min(100, [Math]::Max(0, [int]$battery.EstimatedChargeRemaining))
                [Console]::Out.WriteLine("EDITH_CONTROL_BATTERY_LEVEL=$level")
                $plugged = if ([int]$battery.BatteryStatus -in @(1, 4, 5)) { 0 } else { 1 }
                [Console]::Out.WriteLine("EDITH_CONTROL_BATTERY_PLUGGED_IN=$plugged")
            }
            $brightness = Get-CimInstance -Namespace root/WMI -ClassName WmiMonitorBrightness `
                -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $brightness) {
                [Console]::Out.WriteLine("EDITH_CONTROL_BRIGHTNESS=$([int]$brightness.CurrentBrightness)")
            }
            try {
                [Console]::Out.WriteLine("EDITH_CONTROL_VOLUME=$([EdithAudio]::Level)")
                [Console]::Out.WriteLine("EDITH_CONTROL_MUTED=$(if ([EdithAudio]::Muted) { 1 } else { 0 })")
            } catch {}
            $wifi = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.NdisPhysicalMedium -eq 9 -or
                    $_.InterfaceDescription -match 'Wireless|Wi-Fi|802[.]11'
                } | Select-Object -First 1
            if ($null -ne $wifi) {
                $wifiEnabled = if ($wifi.Status -eq 'Disabled') { 0 } else { 1 }
                [Console]::Out.WriteLine("EDITH_CONTROL_WIFI_ENABLED=$wifiEnabled")
            }
            $bluetooth = Get-PnpDevice -Class Bluetooth -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.InstanceId -match '^(USB|PCI)' -and
                    $_.FriendlyName -match 'Bluetooth|Radio|Adapter'
                } | Select-Object -First 1
            if ($null -ne $bluetooth) {
                $bluetoothEnabled = if ($bluetooth.Status -eq 'OK') { 1 } else { 0 }
                [Console]::Out.WriteLine("EDITH_CONTROL_BLUETOOTH_ENABLED=$bluetoothEnabled")
            }
            if ($null -ne $wifi -and $null -ne $bluetooth) {
                $airplane = if ($wifiEnabled -eq 0 -and $bluetoothEnabled -eq 0) { 1 } else { 0 }
                [Console]::Out.WriteLine("EDITH_CONTROL_AIRPLANE_MODE=$airplane")
            }
            $notificationSettings = Get-ItemProperty `
                -Path 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Notifications/Settings' `
                -ErrorAction SilentlyContinue
            $dnd = if ($null -ne $notificationSettings -and
                [int]$notificationSettings.NOC_GLOBAL_SETTING_TOASTS_ENABLED -eq 0) { 1 } else { 0 }
            [Console]::Out.WriteLine("EDITH_CONTROL_DO_NOT_DISTURB=$dnd")
            """).utf8)

    public static let status = PowerShell.standardInputCommand(byteCount: statusInput.count)

    public static func input(
        for action: MachineControlAction, disruptiveMarker: String
    ) -> Data {
        let script: String
        switch action {
        case .setBrightness(let requested):
            script = """
                $ErrorActionPreference = 'Stop'
                $methods = Get-CimInstance -Namespace root/WMI `
                    -ClassName WmiMonitorBrightnessMethods | Select-Object -First 1
                if ($null -eq $methods) { exit 4 }
                Invoke-CimMethod -InputObject $methods -MethodName WmiSetBrightness `
                    -Arguments @{ Timeout = [uint32]0; Brightness = [byte]\(clamped(requested)) } |
                    Out-Null
                """
        case .setVolume(let requested):
            script = audioSupport + "[EdithAudio]::Level = \(clamped(requested))"
        case .setMuted(let muted):
            script = audioSupport + "[EdithAudio]::Muted = $\(muted)"
        case .setWiFiEnabled(let enabled):
            let action = enabled ? "Enable" : "Disable"
            let marker = enabled ? "" : markerScript(disruptiveMarker)
            script = """
                $ErrorActionPreference = 'Stop'
                $wifi = Get-NetAdapter -Physical |
                    Where-Object {
                        $_.NdisPhysicalMedium -eq 9 -or
                        $_.InterfaceDescription -match 'Wireless|Wi-Fi|802[.]11'
                    }
                if ($null -eq $wifi) { exit 4 }
                \(marker)
                $wifi | \(action)-NetAdapter -Confirm:$false
                """
        case .setBluetoothEnabled(let enabled):
            script = radioCommand(enabled: enabled)
        case .setAirplaneMode(let enabled):
            let adapterAction = enabled ? "Disable" : "Enable"
            let marker = enabled ? markerScript(disruptiveMarker) : ""
            script = """
                $ErrorActionPreference = 'Stop'
                $bluetooth = Get-PnpDevice -Class Bluetooth |
                    Where-Object {
                        $_.InstanceId -match '^(USB|PCI)' -and
                        $_.FriendlyName -match 'Bluetooth|Radio|Adapter'
                    }
                $wifi = Get-NetAdapter -Physical |
                    Where-Object {
                        $_.NdisPhysicalMedium -eq 9 -or
                        $_.InterfaceDescription -match 'Wireless|Wi-Fi|802[.]11'
                    }
                if ($null -eq $bluetooth -and $null -eq $wifi) { exit 4 }
                \(marker)
                if ($null -ne $bluetooth) {
                    $bluetooth | \(adapterAction)-PnpDevice -Confirm:$false
                }
                if ($null -ne $wifi) { $wifi | \(adapterAction)-NetAdapter -Confirm:$false }
                """
        case .setDoNotDisturb(let enabled):
            let value = enabled ? 0 : 1
            script = """
                $path = 'HKCU:/Software/Microsoft/Windows/CurrentVersion/Notifications/Settings'
                New-Item -Path $path -Force | Out-Null
                New-ItemProperty -Path $path -Name NOC_GLOBAL_SETTING_TOASTS_ENABLED `
                    -PropertyType DWord -Value \(value) -Force | Out-Null
                """
        case .setKeyboardBacklight, .setCaffeinateEnabled:
            script = "exit 4"
        }
        return Data(script.utf8)
    }

    public static func execution(
        for action: MachineControlAction, disruptiveMarker: String
    ) -> (command: String, input: Data) {
        let input = input(for: action, disruptiveMarker: disruptiveMarker)
        return (PowerShell.standardInputCommand(byteCount: input.count), input)
    }

    private static func radioCommand(enabled: Bool) -> String {
        let action = enabled ? "Enable" : "Disable"
        return """
            $ErrorActionPreference = 'Stop'
            $radios = Get-PnpDevice -Class Bluetooth |
                Where-Object {
                    $_.InstanceId -match '^(USB|PCI)' -and
                    $_.FriendlyName -match 'Bluetooth|Radio|Adapter'
                }
            if ($null -eq $radios) { exit 4 }
            $radios | \(action)-PnpDevice -Confirm:$false
            """
    }

    private static func markerScript(_ value: String) -> String {
        "[Console]::Error.WriteLine(\(PowerShell.literal(value)))"
    }

    private static func clamped(_ value: Int) -> Int {
        min(max(value, 0), 100)
    }

    private static let audioSupport = """
        $audioSource = @'
        using System;
        using System.Runtime.InteropServices;

        [ComImport]
        [Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        internal class MMDeviceEnumeratorObject {}

        internal enum EDataFlow { Render, Capture, All }
        internal enum ERole { Console, Multimedia, Communications }

        [ComImport]
        [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDeviceEnumerator {
            int NotImpl1();
            int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice device);
        }

        [ComImport]
        [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IMMDevice {
            int Activate(ref Guid id, int context, IntPtr activationParams,
                [MarshalAs(UnmanagedType.IUnknown)] out object instance);
        }

        [ComImport]
        [Guid("5CDF2C82-841E-4546-9722-0CF74078229A")]
        [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        internal interface IAudioEndpointVolume {
            int RegisterControlChangeNotify(IntPtr notify);
            int UnregisterControlChangeNotify(IntPtr notify);
            int GetChannelCount(out uint count);
            int SetMasterVolumeLevel(float level, Guid context);
            int SetMasterVolumeLevelScalar(float level, Guid context);
            int GetMasterVolumeLevel(out float level);
            int GetMasterVolumeLevelScalar(out float level);
            int SetChannelVolumeLevel(uint channel, float level, Guid context);
            int SetChannelVolumeLevelScalar(uint channel, float level, Guid context);
            int GetChannelVolumeLevel(uint channel, out float level);
            int GetChannelVolumeLevelScalar(uint channel, out float level);
            int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, Guid context);
            int GetMute(out bool muted);
        }

        public static class EdithAudio {
            private static IAudioEndpointVolume Endpoint {
                get {
                    var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorObject();
                    IMMDevice device;
                    Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(
                        EDataFlow.Render, ERole.Multimedia, out device));
                    var id = typeof(IAudioEndpointVolume).GUID;
                    object instance;
                    Marshal.ThrowExceptionForHR(device.Activate(ref id, 23, IntPtr.Zero,
                        out instance));
                    return (IAudioEndpointVolume)instance;
                }
            }

            public static int Level {
                get {
                    float value;
                    Marshal.ThrowExceptionForHR(Endpoint.GetMasterVolumeLevelScalar(out value));
                    return (int)Math.Round(value * 100);
                }
                set {
                    Marshal.ThrowExceptionForHR(Endpoint.SetMasterVolumeLevelScalar(
                        Math.Max(0, Math.Min(100, value)) / 100f, Guid.Empty));
                }
            }

            public static bool Muted {
                get {
                    bool value;
                    Marshal.ThrowExceptionForHR(Endpoint.GetMute(out value));
                    return value;
                }
                set {
                    Marshal.ThrowExceptionForHR(Endpoint.SetMute(value, Guid.Empty));
                }
            }
        }
        '@
        Add-Type -TypeDefinition $audioSource -ErrorAction SilentlyContinue

        """
}
