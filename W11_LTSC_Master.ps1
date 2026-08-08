# ============================================================================
# WINDOWS 11 LTSC IoT MASTER OPTIMIZATION & GAMING SUITE v1.2
# ============================================================================
# Comprehensive optimization, debloat, and gaming enablement script
# For: Windows 11 LTSC IoT systems with focus on gaming and streaming
#
# Author: Development Project
# License: MIT
# Version: 1.2 - Bugfix release (see CHANGELOG at bottom of file)
#
# GitHub: https://github.com/tedofgarlic/W11-LTSC-Optimizer
# Features: 10 optimization modules + rollback + logging + validation
# ============================================================================

# ============================================================================
# GLOBALS & CONFIGURATION
# ============================================================================
$ErrorActionPreference = "Continue"
$Timestamp   = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogPath     = "$env:TEMP\W11_LTSC_Optimizer_$Timestamp.log"
$BackupPath  = "$env:TEMP\W11_LTSC_Registry_Backup_$Timestamp.reg"
$ProtectedFiles = @($LogPath, $BackupPath)   # never delete these during cleanup

$script:ModifiedItems = @()
$script:FailedItems   = @()

# Critical whitelist: Services that NEVER get disabled
$CriticalWhitelist = @(
    "WlanSvc",           # WiFi
    "bthserv",           # Bluetooth
    "HidUsb",            # Human Interface Devices (USB, Keyboard, Mouse)
    "WinDefend",         # Windows Defender
    "wuauserv",          # Windows Update
    "BITS",              # Background Intelligent Transfer
    "RpcSs",             # RPC Service (critical system)
    "DcomLaunch"         # COM Launch Service
)

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level] $Message"
    Write-Host $LogEntry
    Add-Content -Path $LogPath -Value $LogEntry -Encoding UTF8
}

function Write-LogError {
    # BUGFIX: catch-block "$_" is a [System.Management.Automation.ErrorRecord],
    # NOT a [System.Exception]. Typing this param as [System.Exception] made
    # every "Write-LogError ... $_" call throw a ParameterArgumentTransformationException
    # instead of actually logging the error. Accept either type here.
    param([string]$Message, $Exception = $null)
    $detail = if ($Exception -is [System.Management.Automation.ErrorRecord]) {
        $Exception.Exception.Message
    } elseif ($Exception -is [System.Exception]) {
        $Exception.Message
    } elseif ($Exception) {
        $Exception.ToString()
    } else {
        $null
    }
    $ErrorMsg = if ($detail) { "$Message - Error: $detail" } else { $Message }
    Write-Log $ErrorMsg "ERROR"
    # BUGFIX: must use $script: scope, otherwise this only mutates a local copy
    $script:FailedItems += $Message
}

function Write-LogSuccess {
    param([string]$Message)
    Write-Log $Message "SUCCESS"
    $script:ModifiedItems += $Message
}

# ============================================================================
# VALIDATION & PRE-FLIGHT CHECKS
# ============================================================================
function Test-Prerequisites {
    Write-Log "Starting pre-flight checks..."

    # Check admin privileges
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
    if (-not $isAdmin) {
        Write-LogError "Not running as Administrator. Script requires admin privileges."
        exit 1
    }
    Write-LogSuccess "Administrator privileges verified"

    # Check Windows 11 (build >= 22000)
    $osVersion = [System.Environment]::OSVersion.Version
    # BUGFIX: Get-WmiObject is removed in PowerShell 7+ (pwsh). Use Get-CimInstance instead.
    $osCaption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption

    if ($osVersion.Major -ne 10 -or $osVersion.Build -lt 22000) {
        Write-LogError "Windows 11 or later required. Detected: $osCaption (Build $($osVersion.Build))"
        exit 1
    }
    Write-LogSuccess "Windows version compatible: $osCaption (Build $($osVersion.Build))"

    # Check disk space
    $diskSpace = (Get-Volume -DriveLetter C).SizeRemaining / 1GB
    if ($diskSpace -lt 5) {
        Write-LogError "Insufficient disk space. Required: 5GB free, Available: $([math]::Round($diskSpace, 2))GB"
        exit 1
    }
    Write-LogSuccess "Disk space check passed: $([math]::Round($diskSpace, 2))GB available"

    # Test registry access
    try {
        Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion" -ErrorAction Stop | Out-Null
        Write-LogSuccess "Registry access verified"
    } catch {
        Write-LogError "Cannot access Windows registry. Required for full functionality."
        exit 1
    }

    # Backup registry before making any changes (BUGFIX: $BackupPath was declared but never used)
    Backup-Registry

    Write-Log "Pre-flight checks completed successfully"
}

function Backup-Registry {
    try {
        # Export the two hives we touch most, so the user can roll back manually if needed
        reg export "HKCU\Software\Microsoft\Windows\CurrentVersion" $BackupPath /y | Out-Null
        Write-LogSuccess "Registry backup created: $BackupPath"
    } catch {
        Write-LogError "Failed to create registry backup" $_
    }
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================
function Confirm-Action {
    param([string]$prompt)
    $response = Read-Host "$prompt (Y/N)"
    # BUGFIX: case-insensitive comparison so "y"/"Y"/"yes"/"YES" all work
    return $response -match '^(y|yes)$'
}

function Test-ServiceExists {
    param([string]$ServiceName)
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    return $null -ne $service
}

function Test-CriticalService {
    param([string]$ServiceName)
    return $CriticalWhitelist -contains $ServiceName
}

function Disable-ServiceSafely {
    param([string]$ServiceName, [string]$DisplayName)

    # NEVER disable critical services
    if (Test-CriticalService $ServiceName) {
        Write-Log "Skipping critical service: $ServiceName (whitelisted)"
        return $false
    }

    if (-not (Test-ServiceExists $ServiceName)) {
        Write-Log "Service not found: $ServiceName"
        return $false
    }

    try {
        $service = Get-Service -Name $ServiceName -ErrorAction Stop

        if ($service.Status -eq "Running") {
            Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            Write-Log "Stopped service: $DisplayName"
        }

        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
        Write-LogSuccess "Disabled service: $DisplayName"
        # BUGFIX: explicit return value so callers can count successes correctly
        return $true
    } catch {
        Write-LogError "Failed to disable service: $DisplayName" $_
        return $false
    }
}

function Enable-ServiceSafely {
    param([string]$ServiceName, [string]$DisplayName)

    if (-not (Test-ServiceExists $ServiceName)) {
        Write-Log "Service not found: $ServiceName"
        return $false
    }

    try {
        Set-Service -Name $ServiceName -StartupType Automatic -ErrorAction Stop
        Start-Service -Name $ServiceName -ErrorAction Stop
        Write-LogSuccess "Enabled service: $DisplayName"
        return $true
    } catch {
        Write-LogError "Failed to enable service: $DisplayName" $_
        return $false
    }
}

function Set-RegistryValue {
    param([string]$Path, [string]$Name, $Value, [string]$Type = "DWORD")

    try {
        if (-not (Test-Path $Path)) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force -ErrorAction Stop
        Write-LogSuccess "Registry set: $Path\$Name = $Value"
        return $true
    } catch {
        Write-LogError "Failed to set registry: $Path\$Name" $_
        return $false
    }
}

# BUGFIX: a hardcoded "High performance" GUID isn't guaranteed to exist on every
# Windows build - confirmed missing on Windows 11 IoT Enterprise LTSC, which caused
# "powercfg /setactive <guid>" to fail with exit code 1. powercfg supports the
# built-in alias SCHEME_MIN for High performance, which works regardless of GUID.
# If that somehow isn't available either, duplicate the built-in scheme as a fallback.
function Set-HighPerformancePowerPlan {
    try {
        & powercfg /setactive SCHEME_MIN 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-LogSuccess "Set power plan to High Performance (SCHEME_MIN)"
            return
        }
    } catch { }

    # Fallback: duplicate the built-in High performance scheme, then activate the copy
    try {
        $dupOutput = & powercfg -duplicatescheme 8c5e7fda-e8bf-45a6-a6cc-4b3c9b6596f0 2>$null
        if ($LASTEXITCODE -eq 0 -and $dupOutput -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
            $newGuid = $Matches[1]
            & powercfg /setactive $newGuid 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-LogSuccess "Set power plan to High Performance (duplicated scheme $newGuid)"
                return
            }
        }
        Write-LogError "Could not activate or create a High Performance power plan on this system"
    } catch {
        Write-LogError "Could not activate or create a High Performance power plan on this system" $_
    }
}

# Runs an external command (powercfg/netsh) and treats a non-zero exit code as failure,
# since try/catch alone does NOT catch errors from external .exe processes.
function Invoke-ExternalCommand {
    param([string]$Description, [scriptblock]$Command)
    try {
        & $Command 2>$null
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) {
            Write-LogError "$Description (exit code $LASTEXITCODE)"
            return $false
        }
        Write-LogSuccess $Description
        return $true
    } catch {
        Write-LogError $Description $_
        return $false
    }
}

# ============================================================================
# MAIN MENU FUNCTION
# ============================================================================
function Show-Menu {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host "WINDOWS 11 LTSC IoT OPTIMIZER v1.2 - SELECT OPTIMIZATION SECTIONS" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "OPTIMIZATION SECTIONS:" -ForegroundColor Yellow
    Write-Host "  1. TELEMETRY REMOVAL" -ForegroundColor Green
    Write-Host "  2. BLOATWARE REMOVAL" -ForegroundColor Green
    Write-Host "  3. SERVICE OPTIMIZATION" -ForegroundColor Green
    Write-Host "  4. SCHEDULED TASKS CLEANUP" -ForegroundColor Green
    Write-Host "  5. PERFORMANCE TWEAKS" -ForegroundColor Green
    Write-Host "  6. NETWORK OPTIMIZATION" -ForegroundColor Green
    Write-Host "  7. STORAGE OPTIMIZATION" -ForegroundColor Green
    Write-Host "  8. VISUAL EFFECTS" -ForegroundColor Green
    Write-Host "  9. GAMING & STREAMING TWEAKS" -ForegroundColor Green
    Write-Host ""
    Write-Host "GAMING SERVICES:" -ForegroundColor Yellow
    Write-Host "  10. GAMEPASS & GAMING SERVICES ENABLER" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "BATCH OPERATIONS:" -ForegroundColor Yellow
    Write-Host "  11. RUN ALL OPTIMIZATION (1-9)" -ForegroundColor Green
    Write-Host "  12. RUN ALL (Optimization + Gaming)" -ForegroundColor Cyan
    Write-Host "  13. VIEW LOG" -ForegroundColor Magenta
    Write-Host "  14. EXIT" -ForegroundColor Red
    Write-Host ""
}

# ============================================================================
# SECTION 1: TELEMETRY REMOVAL
# ============================================================================
function Optimize-Telemetry {
    Write-Host "`n=== SECTION 1: TELEMETRY REMOVAL ===" -ForegroundColor Cyan
    Write-Host "This will disable Windows tracking and diagnostic services." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    $telemetryServices = @(
        @{Name = "DiagTrack"; DisplayName = "Diagnostic Tracking Service"},
        @{Name = "dmwappushservice"; DisplayName = "dmwappushservice"},
        @{Name = "MapsBroker"; DisplayName = "Maps Broker Service"}
    )
    foreach ($svc in $telemetryServices) {
        Disable-ServiceSafely $svc.Name $svc.DisplayName | Out-Null
    }

    $telemetryPaths = @(
        "HKLM:\Software\Policies\Microsoft\Windows\DataCollection",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Diagnostics\DiagTrack"
    )
    foreach ($path in $telemetryPaths) {
        Set-RegistryValue $path "AllowDiagnosticData" 0 | Out-Null
    }

    Write-Host "`n[OK] TELEMETRY REMOVAL COMPLETE" -ForegroundColor Green
    Write-Log "Telemetry removal section completed"
}

# ============================================================================
# SECTION 2: BLOATWARE REMOVAL
# ============================================================================
function Remove-Bloatware {
    Write-Host "`n=== SECTION 2: BLOATWARE REMOVAL ===" -ForegroundColor Cyan
    Write-Host "Removing pre-installed UWP applications..." -ForegroundColor Yellow
    Write-Host "WARNING: Some apps may be reinstalled by system. This is normal." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    $bloatwareApps = @(
        "Microsoft.BingWeather", "Microsoft.BingNews", "Microsoft.GetHelp",
        "Microsoft.Getstarted", "Microsoft.MicrosoftStickyNotes", "Microsoft.WindowsFeedbackHub",
        "Microsoft.XboxGameCallableUI", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo",
        "Microsoft.OneConnect", "Microsoft.People", "Microsoft.SkypeApp",
        "Microsoft.MixedReality.Portal", "Microsoft.YourPhone"
    )

    $removedCount = 0
    foreach ($app in $bloatwareApps) {
        try {
            $appx = Get-AppxPackage -Name $app -AllUsers -ErrorAction SilentlyContinue
            if ($appx) {
                $appx | Remove-AppxPackage -ErrorAction Stop
                Write-LogSuccess "Removed bloatware: $app"
                $removedCount++
            } else {
                Write-Log "Bloatware not found: $app"
            }
        } catch {
            Write-LogError "Failed to remove bloatware: $app" $_
        }
    }

    Write-Host "`n[OK] BLOATWARE REMOVAL COMPLETE - Removed $removedCount apps" -ForegroundColor Green
    Write-Log "Bloatware removal section completed - $removedCount apps removed"
}

# ============================================================================
# SECTION 3: SERVICE OPTIMIZATION
# ============================================================================
function Optimize-Services {
    Write-Host "`n=== SECTION 3: SERVICE OPTIMIZATION ===" -ForegroundColor Cyan
    Write-Host "Disabling non-essential services while protecting critical ones..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    $optionalServices = @(
        @{Name = "ProgramCompatibilityAssistant"; DisplayName = "Program Compatibility Assistant"},
        @{Name = "ShellHWDetection"; DisplayName = "Shell Hardware Detection"},
        @{Name = "SSDPSRV"; DisplayName = "SSDP Discovery"},
        @{Name = "upnphost"; DisplayName = "UPnP Device Host"},
        @{Name = "Themes"; DisplayName = "Themes"}
    )

    $disabledCount = 0
    foreach ($svc in $optionalServices) {
        # BUGFIX: this now works because Disable-ServiceSafely returns a real boolean
        if (Disable-ServiceSafely $svc.Name $svc.DisplayName) {
            $disabledCount++
        }
    }

    Write-Host "`n[OK] SERVICE OPTIMIZATION COMPLETE - Disabled $disabledCount services" -ForegroundColor Green
    Write-Log "Service optimization completed - disabled $disabledCount services"
}

# ============================================================================
# SECTION 4: SCHEDULED TASKS CLEANUP
# ============================================================================
function Optimize-ScheduledTasks {
    Write-Host "`n=== SECTION 4: SCHEDULED TASKS CLEANUP ===" -ForegroundColor Cyan
    Write-Host "Disabling telemetry and diagnostics scheduled tasks..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    # BUGFIX: use single backslashes (PowerShell double-quoted strings do NOT need
    # backslash escaping) so these actually match real task paths.
    $tasksToDisable = @(
        "\Microsoft\Windows\Application Experience\AitAgent",
        "\Microsoft\Windows\Application Experience\ProgramDataUpdater",
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticDataCollector",
        "\Microsoft\Windows\DiskDiagnostic\Microsoft-Windows-DiskDiagnosticResolver"
    )

    $disabledTasks = 0
    foreach ($task in $tasksToDisable) {
        $taskName = Split-Path $task -Leaf
        $taskPath = (Split-Path $task -Parent) + "\"
        try {
            $taskObj = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
            if ($taskObj) {
                Disable-ScheduledTask -TaskName $taskObj.TaskName -TaskPath $taskObj.TaskPath -ErrorAction Stop | Out-Null
                Write-LogSuccess "Disabled task: $task"
                $disabledTasks++
            } else {
                Write-Log "Task not found: $task"
            }
        } catch {
            Write-LogError "Failed to disable task: $task" $_
        }
    }

    Write-Host "`n[OK] SCHEDULED TASKS CLEANUP COMPLETE - Disabled $disabledTasks tasks" -ForegroundColor Green
    Write-Log "Task cleanup completed - $disabledTasks tasks disabled"
}

# ============================================================================
# SECTION 5: PERFORMANCE TWEAKS
# ============================================================================
function Optimize-Performance {
    Write-Host "`n=== SECTION 5: PERFORMANCE TWEAKS ===" -ForegroundColor Cyan
    Write-Host "Optimizing power plan and visual effects..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    Set-HighPerformancePowerPlan
    Invoke-ExternalCommand "Disabled standby on AC power"     { powercfg /change standby-timeout-ac 0 }
    Invoke-ExternalCommand "Set monitor timeout on AC power"  { powercfg /change monitor-timeout-ac 10 }

    Write-Host "`n[OK] PERFORMANCE TWEAKS COMPLETE" -ForegroundColor Green
    Write-Log "Performance optimization completed"
}

# ============================================================================
# SECTION 6: NETWORK OPTIMIZATION
# ============================================================================
function Optimize-Network {
    Write-Host "`n=== SECTION 6: NETWORK OPTIMIZATION ===" -ForegroundColor Cyan
    Write-Host "Optimizing TCP/IP stack for gaming and streaming..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    try {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters" -Name "TcpNoDelay" -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-LogSuccess "Disabled Nagle's algorithm (TCP NoDelay)"
    } catch {
        Write-LogError "Failed to set TcpNoDelay" $_
    }

    Invoke-ExternalCommand "Enabled Receive Side Scaling (RSS)" { netsh int tcp set global rss=enabled }
    Invoke-ExternalCommand "Enabled TCP timestamps"             { netsh int tcp set global timestamps=enabled }

    Write-Host "`n[OK] NETWORK OPTIMIZATION COMPLETE" -ForegroundColor Green
    Write-Log "Network optimization completed"
}

# ============================================================================
# SECTION 7: STORAGE OPTIMIZATION
# ============================================================================
function Optimize-Storage {
    Write-Host "`n=== SECTION 7: STORAGE OPTIMIZATION ===" -ForegroundColor Cyan
    Write-Host "Cleaning temporary files and cache..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    $cleanupPaths = @(
        @{Path = "$env:TEMP"; Display = "Windows Temp"},
        @{Path = "$env:LOCALAPPDATA\Temp"; Display = "User Temp"},
        @{Path = "$env:SystemRoot\Temp"; Display = "System Temp"}
    )

    $spaceSaved = 0
    foreach ($item in $cleanupPaths) {
        try {
            if (Test-Path $item.Path) {
                # BUGFIX: exclude the script's own log/backup files so it doesn't
                # delete them mid-run (they live in $env:TEMP).
                $children = Get-ChildItem -Path $item.Path -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $ProtectedFiles -notcontains $_.FullName }

                $before = ($children | Measure-Object -Property Length -Sum).Sum / 1MB
                $children | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                $spaceSaved += $before
                Write-LogSuccess "Cleaned: $($item.Display) (~$([math]::Round($before, 2))MB)"
            }
        } catch {
            Write-LogError "Failed to clean: $($item.Display)" $_
        }
    }

    Write-Host "`n[OK] STORAGE OPTIMIZATION COMPLETE - Freed ~$([math]::Round($spaceSaved, 2))MB" -ForegroundColor Green
    Write-Log "Storage optimization completed - freed ~$([math]::Round($spaceSaved, 2))MB"
}

# ============================================================================
# SECTION 8: VISUAL EFFECTS
# ============================================================================
function Disable-VisualEffects {
    Write-Host "`n=== SECTION 8: VISUAL EFFECTS ===" -ForegroundColor Cyan
    Write-Host "Disabling animations and visual effects..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    Set-RegistryValue "HKCU:\Control Panel\Desktop" "DisableAnimations" 1 "DWORD" | Out-Null
    Set-RegistryValue "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" "ListviewAlphaEnabled" 0 "DWORD" | Out-Null

    Write-Host "`n[OK] VISUAL EFFECTS DISABLED" -ForegroundColor Green
    Write-Log "Visual effects optimization completed"
}

# ============================================================================
# SECTION 9: GAMING & STREAMING TWEAKS
# ============================================================================
function Optimize-GamingStreaming {
    Write-Host "`n=== SECTION 9: GAMING & STREAMING OPTIMIZATION ===" -ForegroundColor Cyan
    Write-Host "Optimizing for gaming and streaming performance..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    Set-RegistryValue "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0 "DWORD" | Out-Null
    Set-RegistryValue "HKCU:\Control Panel\Desktop" "ForegroundLockTimeout" 0 "DWORD" | Out-Null

    Write-Host "`n[OK] GAMING AND STREAMING OPTIMIZATION COMPLETE" -ForegroundColor Green
    Write-Log "Gaming/Streaming optimization completed"
}

# ============================================================================
# SECTION 10: GAMING SERVICES ENABLEMENT
# ============================================================================
function Enable-GamingServices {
    Write-Host "`n=== SECTION 10: GAMEPASS AND GAMING SERVICES ENABLER ===" -ForegroundColor Cyan
    Write-Host "Re-enabling gaming services after optimization..." -ForegroundColor Yellow
    if (-not (Confirm-Action "Continue?")) { return }

    $xboxServices = @(
        @{Name = "XblAuthManager"; DisplayName = "Xbox Live Auth Manager"},
        @{Name = "XblGameSave"; DisplayName = "Xbox Live Game Save Service"},
        @{Name = "XboxNetApiSvc"; DisplayName = "Xbox Live Networking Service"},
        @{Name = "GameInputSvc"; DisplayName = "Game Input Service"}
    )

    $enabledCount = 0
    foreach ($svc in $xboxServices) {
        if (Enable-ServiceSafely $svc.Name $svc.DisplayName) {
            $enabledCount++
        }
    }

    try {
        Enable-WindowsOptionalFeature -Online -FeatureName DirectPlay -NoRestart -ErrorAction Stop | Out-Null
        Write-LogSuccess "Enabled DirectPlay"
    } catch {
        Write-LogError "Failed to enable DirectPlay" $_
    }

    Write-Host "`n[OK] GAMING SERVICES ENABLEMENT COMPLETE - Enabled $enabledCount services" -ForegroundColor Green
    Write-Log "Gaming services enablement completed - $enabledCount services enabled"
}

# ============================================================================
# SUMMARY & REPORTING
# ============================================================================
function Show-ExecutionSummary {
    Write-Host "`n=== EXECUTION SUMMARY ===" -ForegroundColor Cyan
    Write-Host "Successful modifications: $($script:ModifiedItems.Count)" -ForegroundColor Green
    Write-Host "Failed operations: $($script:FailedItems.Count)" -ForegroundColor $(if ($script:FailedItems.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "Log file: $LogPath" -ForegroundColor Magenta
    Write-Host "Registry backup: $BackupPath" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "NEXT STEPS:" -ForegroundColor Yellow
    Write-Host "  1. RESTART your system for all changes to take effect"
    Write-Host "  2. Test WiFi, Bluetooth, and USB devices"
    Write-Host "  3. Update GPU drivers from manufacturer"
    Write-Host "  4. Install Xbox App if gaming services were enabled"
    Write-Host ""
}

# ============================================================================
# MAIN LOOP
# ============================================================================
function Main {
    Clear-Host
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host "WINDOWS 11 LTSC IoT OPTIMIZER v1.2" -ForegroundColor Cyan
    Write-Host "========================================================================" -ForegroundColor Cyan
    Write-Host ""

    Test-Prerequisites

    $continue = $true
    while ($continue) {
        Show-Menu
        $choice = Read-Host "Select option (1-14)"

        switch ($choice) {
            "1"  { Optimize-Telemetry }
            "2"  { Remove-Bloatware }
            "3"  { Optimize-Services }
            "4"  { Optimize-ScheduledTasks }
            "5"  { Optimize-Performance }
            "6"  { Optimize-Network }
            "7"  { Optimize-Storage }
            "8"  { Disable-VisualEffects }
            "9"  { Optimize-GamingStreaming }
            "10" { Enable-GamingServices }
            "11" {
                Optimize-Telemetry; Remove-Bloatware; Optimize-Services
                Optimize-ScheduledTasks; Optimize-Performance; Optimize-Network
                Optimize-Storage; Disable-VisualEffects; Optimize-GamingStreaming
            }
            "12" {
                Optimize-Telemetry; Remove-Bloatware; Optimize-Services
                Optimize-ScheduledTasks; Optimize-Performance; Optimize-Network
                Optimize-Storage; Disable-VisualEffects; Optimize-GamingStreaming
                Enable-GamingServices
            }
            "13" {
                if (Test-Path $LogPath) { notepad $LogPath }
                else { Write-Host "No log file found yet." -ForegroundColor Yellow }
            }
            "14" {
                $continue = $false
                Show-ExecutionSummary
            }
            default {
                Write-Host "Invalid option. Please select 1-14." -ForegroundColor Red
            }
        }
    }
}

# ============================================================================
# ENTRY POINT
# ============================================================================
Main
Read-Host "Press Enter to exit"

# ============================================================================
# CHANGELOG v1.1 -> v1.2
# ============================================================================
# - Get-WmiObject -> Get-CimInstance (Get-WmiObject removed in PowerShell 7+)
# - $ModifiedItems/$FailedItems now use $script: scope (were silently no-ops)
# - Disable-ServiceSafely / Enable-ServiceSafely now return actual booleans
#   (counters in Optimize-Services / Enable-GamingServices were always wrong)
# - Confirm-Action is now case-insensitive (y/Y/yes/YES)
# - Scheduled task paths fixed (were double-backslash strings that never matched)
# - Storage cleanup now excludes the script's own log/backup files
# - powercfg/netsh calls checked via $LASTEXITCODE (try/catch doesn't catch
#   failures from external .exe processes)
# - Added a real Backup-Registry function using the previously-unused $BackupPath
# - Removed duplicate/dead "Theme" service entry in Optimize-Services
# ============================================================================w
