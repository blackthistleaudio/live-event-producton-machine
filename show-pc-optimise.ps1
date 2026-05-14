#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Show PC Optimisation Script
    Windows 11 Pro | Reaper + Dante Virtual Soundcard
.DESCRIPTION
    Disables Defender, Windows Update, unnecessary services, applies power
    and audio optimisations for low-latency live recording.
    Run once on a DEDICATED show machine only.
    Create a restore point before running:
        Checkpoint-Computer -Description "Pre-ShowPC-Optimise" -RestorePointType "MODIFY_SETTINGS"
.NOTES
    Version: 1.0
    Re-enable Defender before connecting to any general-purpose network.
#>

$ErrorActionPreference = "SilentlyContinue"
$LogFile = "$env:USERPROFILE\Desktop\ShowPC-Optimise-Log.txt"

function Log {
    param([string]$msg, [string]$type = "INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$type] $msg"
    Write-Host $line -ForegroundColor $(if($type -eq "OK"){"Green"} elseif($type -eq "WARN"){"Yellow"} elseif($type -eq "ERR"){"Red"} else {"Cyan"})
    Add-Content -Path $LogFile -Value $line
}

function Section {
    param([string]$title)
    $sep = "=" * 60
    Write-Host "`n$sep" -ForegroundColor DarkCyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "$sep" -ForegroundColor DarkCyan
    Add-Content -Path $LogFile -Value "`n$sep`n  $title`n$sep"
}

function DisableService {
    param([string]$name)
    try {
        $svc = Get-Service -Name $name
        if ($svc) {
            Stop-Service -Name $name -Force
            Set-Service  -Name $name -StartupType Disabled
            Log "Service disabled: $name" "OK"
        }
    } catch {
        Log "Could not disable service: $name -- $_" "WARN"
    }
}

# --- RESTORE POINT ------------------------------------------------------------
Section "Creating Restore Point"
try {
    Enable-ComputerRestore -Drive "C:\"
    Checkpoint-Computer -Description "Pre-ShowPC-Optimise" -RestorePointType "MODIFY_SETTINGS"
    Log "Restore point created" "OK"
} catch {
    Log "Restore point failed (may already exist within 24h): $_" "WARN"
}

# --- SECTION 1: DEFENDER ------------------------------------------------------
Section "Disabling Windows Defender"

# Tamper Protection must be disabled manually in Windows Security UI first.
# GPO approach:
$defPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender"
if (!(Test-Path $defPath)) { New-Item -Path $defPath -Force | Out-Null }
Set-ItemProperty -Path $defPath -Name "DisableAntiSpyware" -Value 1 -Type DWord
Log "Defender DisableAntiSpyware GPO set" "OK"

# Disable Real-Time Protection settings
$rtpPath = "$defPath\Real-Time Protection"
if (!(Test-Path $rtpPath)) { New-Item -Path $rtpPath -Force | Out-Null }
Set-ItemProperty -Path $rtpPath -Name "DisableRealtimeMonitoring"   -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name "DisableBehaviorMonitoring"   -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name "DisableOnAccessProtection"   -Value 1 -Type DWord
Set-ItemProperty -Path $rtpPath -Name "DisableScanOnRealtimeEnable" -Value 1 -Type DWord
Log "Real-Time Protection registry keys disabled" "OK"

# Disable SmartScreen
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableSmartScreen" -Value 0 -Type DWord
Log "SmartScreen disabled" "OK"

# Disable Defender scheduled tasks
$defTasks = @(
    "Microsoft\Windows\Windows Defender\Windows Defender Cache Maintenance",
    "Microsoft\Windows\Windows Defender\Windows Defender Cleanup",
    "Microsoft\Windows\Windows Defender\Windows Defender Scheduled Scan",
    "Microsoft\Windows\Windows Defender\Windows Defender Verification"
)
foreach ($t in $defTasks) {
    try {
        Disable-ScheduledTask -TaskPath "\$(Split-Path $t)\\" -TaskName (Split-Path $t -Leaf) | Out-Null
        Log "Scheduled task disabled: $t" "OK"
    } catch {
        Log "Could not disable task: $t" "WARN"
    }
}

DisableService "SecurityHealthService"
DisableService "WinDefend"
DisableService "wscsvc"  # Security Center

# --- SECTION 2: WINDOWS UPDATE ------------------------------------------------
Section "Disabling Windows Update"

DisableService "wuauserv"    # Windows Update
DisableService "UsoSvc"      # Update Orchestrator
DisableService "DoSvc"       # Delivery Optimisation
DisableService "WaaSMedicSvc" # Medic (self-healer) -- may require ownership

# GPO block
$wuPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
if (!(Test-Path $wuPath)) { New-Item -Path $wuPath -Force | Out-Null }
Set-ItemProperty -Path $wuPath -Name "NoAutoUpdate"   -Value 1 -Type DWord
Set-ItemProperty -Path $wuPath -Name "AUOptions"      -Value 1 -Type DWord
Log "Windows Update GPO blocked" "OK"

# WaaSMedicSvc self-healer -- requires registry ownership (best done via script elevation)
$medicKey = "HKLM:\SYSTEM\CurrentControlSet\Services\WaaSMedicSvc"
try {
    # Take ownership and set start to Disabled (4)
    $acl = Get-Acl $medicKey
    $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name,
        "FullControl", "Allow")
    $acl.SetAccessRule($rule)
    Set-Acl $medicKey $acl
    Set-ItemProperty -Path $medicKey -Name "Start" -Value 4 -Type DWord
    Log "WaaSMedicSvc disabled via registry" "OK"
} catch {
    Log "WaaSMedicSvc registry change failed -- may need manual ownership via regedit: $_" "WARN"
}

# --- SECTION 3: UNNECESSARY SERVICES -----------------------------------------
Section "Disabling Unnecessary Services"

$services = @(
    "SysMain",           # Superfetch
    "WSearch",           # Windows Search / Indexer
    "DiagTrack",         # Connected User Experiences & Telemetry
    "Spooler",           # Print Spooler
    "Fax",               # Fax
    "RemoteRegistry",    # Remote Registry
    "XblAuthManager",    # Xbox Live Auth
    "XblGameSave",       # Xbox Game Save
    "XboxNetApiSvc",     # Xbox Network
    "GamingServices",    # Gaming Services
    "WerSvc",            # Windows Error Reporting
    "dmwappushservice",  # WAP Push
    "bthserv",           # Bluetooth (disable only if no BT devices)
    "MSIXStoreService",  # Microsoft Store Install
    "seclogon"           # Secondary Logon
)

foreach ($s in $services) { DisableService $s }

# --- SECTION 4: POWER & CPU ---------------------------------------------------
Section "Power Plan & CPU Optimisation"

# High Performance power plan
powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c
Log "High Performance power plan activated" "OK"

# Disable hibernate
powercfg /h off
Log "Hibernate disabled" "OK"

# Sleep timeout = 0 (Never) on AC
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change disk-timeout-ac 0
Log "Sleep/monitor/disk timeouts set to Never" "OK"

# USB Selective Suspend -- disable via registry
$usbPath = "HKLM:\SYSTEM\CurrentControlSet\Services\USB"
Set-ItemProperty -Path $usbPath -Name "DisableSelectiveSuspend" -Value 1 -Type DWord -ErrorAction SilentlyContinue
Log "USB Selective Suspend disabled" "OK"

# Processor minimum state = 100% (prevents C-state drops)
# GUID for the active High Performance plan
$planGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
$subGuid  = "54533251-82be-4824-96c1-47b60b740d00"  # Processor power mgmt
$minGuid  = "893dee8e-2bef-41e0-89c6-b55d0929964c"  # Minimum processor state
powercfg /setacvalueindex $planGuid $subGuid $minGuid 100
Log "Processor minimum state set to 100%" "OK"

# --- SECTION 5: VISUAL & OS OVERHEAD -----------------------------------------
Section "Visual Effects & OS Overhead"

# Best performance visual settings
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Type DWord
Log "Visual effects set to best performance" "OK"

# Disable transparency
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0 -Type DWord
Log "Transparency disabled" "OK"

# Disable Game Mode
Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 0 -Type DWord
Set-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Value 0 -Type DWord
Log "Game Mode disabled" "OK"

# Disable Game Bar
Set-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -Type DWord -ErrorAction SilentlyContinue
Log "Xbox Game Bar / DVR disabled" "OK"

# Disable notifications
$notifPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
Set-ItemProperty -Path $notifPath -Name "ToastEnabled" -Value 0 -Type DWord
Log "Toast notifications disabled" "OK"

# Disable Widgets
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Type DWord -ErrorAction SilentlyContinue
Log "Widgets (News & Interests) disabled" "OK"

# Disable Hardware-Accelerated GPU Scheduling
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 1 -Type DWord
Log "Hardware-Accelerated GPU Scheduling disabled" "OK"

# --- SECTION 6: TELEMETRY & NETWORK ------------------------------------------
Section "Telemetry & Network Noise"

# Disable telemetry
$dcPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"
if (!(Test-Path $dcPath)) { New-Item -Path $dcPath -Force | Out-Null }
Set-ItemProperty -Path $dcPath -Name "AllowTelemetry" -Value 0 -Type DWord
Log "Telemetry disabled via GPO" "OK"

# Disable Windows Error Reporting
$werPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting"
if (!(Test-Path $werPath)) { New-Item -Path $werPath -Force | Out-Null }
Set-ItemProperty -Path $werPath -Name "Disabled" -Value 1 -Type DWord
Log "Windows Error Reporting disabled" "OK"

# Windows Time service to Manual
Set-Service -Name "W32Time" -StartupType Manual
Log "Windows Time set to Manual startup" "OK"

# --- SECTION 7: AUDIO -- DANTE NIC OPTIMISATION -------------------------------
Section "Dante NIC Optimisation (TCP/IP)"

# Disable Nagle's Algorithm on all NICs (improves TCP latency for Dante)
$tcpInterfaces = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
Get-ChildItem $tcpInterfaces | ForEach-Object {
    Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay"      -Value 1 -Type DWord -ErrorAction SilentlyContinue
}
Log "Nagle's Algorithm disabled on all NIC interfaces" "OK"

Log "NOTE: Also manually disable Interrupt Moderation on your Dante NIC via Device Manager -> NIC -> Properties -> Advanced" "WARN"
Log "NOTE: Disable power management on your Dante NIC via Device Manager -> NIC -> Properties -> Power Management" "WARN"

# --- DONE ---------------------------------------------------------------------
Section "Complete"
Log "All optimisations applied. Log saved to: $LogFile" "OK"
Log "NEXT STEPS:" "WARN"
Log "  1. Reboot" "WARN"
Log "  2. Disable Tamper Protection manually in Windows Security (if not done)" "WARN"
Log "  3. Disable power management on Dante NIC in Device Manager" "WARN"
Log "  4. Set Dante VSC latency to match Reaper buffer" "WARN"
Log "  5. Run LatencyMon for 10 min to verify DPC latency is green" "WARN"
Log "  6. Do a rehearsal record and check waveform for dropouts" "WARN"

Write-Host "`nPress any key to exit..." -ForegroundColor DarkCyan
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
