#Requires -Version 7.5

[CmdletBinding()]
param(
    [string]$SettingsPath = '',
    [string]$LogDirectory = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-StartupPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DefaultPath
    )

    $candidate = if ([string]::IsNullOrWhiteSpace($Path)) { $DefaultPath } else { $Path }
    if (-not [System.IO.Path]::IsPathRooted($candidate)) {
        $candidate = Join-Path $PSScriptRoot $candidate
    }
    return [System.IO.Path]::GetFullPath($candidate)
}

function Wait-ExplorerReady {
    param(
        [int]$TimeoutSeconds = 30
    )

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        if ($null -ne (Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            return $true
        }
        Start-Sleep -Milliseconds 200
    }

    return $false
}

$resolvedSettingsPath = Resolve-StartupPath -Path $SettingsPath -DefaultPath (Join-Path $PSScriptRoot 'virtual-desktop-setting.json')
$resolvedLogDirectory = Resolve-StartupPath -Path $LogDirectory -DefaultPath (Join-Path $PSScriptRoot 'logs')
$null = New-Item -ItemType Directory -Path $resolvedLogDirectory -Force
$logFilePath = Join-Path $resolvedLogDirectory ("startup-virtual-desktop-{0}-{1}.jsonl" -f [datetime]::Now.ToString('yyyyMMdd-HHmmss'), $PID)
$loggerLogFilePath = $logFilePath
$logger = {
    param($Level, $Message, $Data)

    $entry = [ordered]@{
        timestamp = [datetime]::UtcNow.ToString('o')
        level = $Level
        message = $Message
        data = $Data
    }
    $line = $entry | ConvertTo-Json -Depth 12 -Compress
    $null = Add-Content -LiteralPath $loggerLogFilePath -Value $line -Encoding utf8
}.GetNewClosure()

$mutex = $null
$ownsMutex = $false
$exitCode = 2

try {
    $mutexUser = [regex]::Replace([Environment]::UserName, '[^A-Za-z0-9_.-]', '_')
    $mutex = [System.Threading.Mutex]::new($false, "Local\StartupVirtualDesktop-$mutexUser")
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }

    if (-not $ownsMutex) {
        & $logger 'Warning' 'Another startup virtual desktop run is already active.' $null
        Write-Warning 'Another startup virtual desktop run is already active; this run will exit.'
        $exitCode = 0
    } else {
        $coreModulePath = Join-Path $PSScriptRoot 'modules\StartupVirtualDesktop.Core.psm1'
        $windowsModulePath = Join-Path $PSScriptRoot 'modules\StartupVirtualDesktop.Windows.psm1'
        Import-Module $coreModulePath -Force -ErrorAction Stop
        Import-Module $windowsModulePath -Force -ErrorAction Stop

        $diagnostics = Get-StartupEnvironmentDiagnostics
        & $logger 'Info' 'Startup environment detected.' $diagnostics

        if (-not (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf)) {
            throw "Settings file '$resolvedSettingsPath' does not exist."
        }

        $rawSettings = Get-Content -LiteralPath $resolvedSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $settings = ConvertTo-DesktopLayoutSettings -InputObject $rawSettings
        $null = Test-DesktopLayoutSettings -Settings $settings
        foreach ($warning in @($settings.warnings)) {
            & $logger 'Warning' $warning $null
            Write-Warning $warning
        }

        if ([string]::IsNullOrWhiteSpace($diagnostics.VirtualDesktopModuleVersion)) {
            & $logger 'Warning' 'VirtualDesktop module is not installed.' $null
        } else {
            $installedModuleVersion = [version]$diagnostics.VirtualDesktopModuleVersion
            if ($installedModuleVersion -lt [version]'1.5.11') {
                $versionWarning = "VirtualDesktop $installedModuleVersion is installed; 1.5.11 or later is recommended."
                & $logger 'Warning' $versionWarning $null
                Write-Warning $versionWarning
            }
        }

        if ($ValidateOnly) {
            & $logger 'Info' 'Settings validation succeeded.' @{ settingsPath = $resolvedSettingsPath }
            Write-Output "Settings validation succeeded: $resolvedSettingsPath"
            $exitCode = 0
        } else {
            if ([string]::IsNullOrWhiteSpace($diagnostics.VirtualDesktopModuleVersion) -or
                [version]$diagnostics.VirtualDesktopModuleVersion -lt [version]'1.5.9') {
                throw 'VirtualDesktop module 1.5.9 or later is required. Run Install-Module VirtualDesktop -Scope CurrentUser.'
            }

            Import-Module VirtualDesktop -MinimumVersion 1.5.9 -Force -ErrorAction Stop
            if (-not (Wait-ExplorerReady -TimeoutSeconds 30)) {
                throw 'Windows Explorer was not ready within 30 seconds.'
            }

            $adapter = New-WindowsDesktopAdapter
            $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $adapter -Log $logger)
            $failedCount = @($results | Where-Object Status -eq 'Failed').Count
            $summary = [ordered]@{
                total = $results.Count
                moved = @($results | Where-Object Status -eq 'Moved').Count
                alreadyPlaced = @($results | Where-Object Status -eq 'AlreadyPlaced').Count
                skipped = @($results | Where-Object Status -eq 'Skipped').Count
                failed = $failedCount
            }
            & $logger $(if ($failedCount -gt 0) { 'Error' } else { 'Info' }) 'Desktop layout reconciliation completed.' $summary
            Write-Output ("Desktop layout completed: {0} total, {1} failed. Log: {2}" -f $results.Count, $failedCount, $logFilePath)
            $exitCode = if ($failedCount -gt 0) { 1 } else { 0 }
        }
    }
} catch {
    try {
        & $logger 'Error' 'Startup virtual desktop failed.' @{ error = $_.Exception.Message }
    } catch {
        # Logging failure must not hide the original error.
    }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 2
} finally {
    if ($ownsMutex -and $null -ne $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

exit $exitCode
