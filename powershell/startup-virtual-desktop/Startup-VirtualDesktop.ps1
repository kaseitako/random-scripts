#Requires -Version 7.5

[CmdletBinding()]
param(
    [string]$SettingsPath = '',
    [string]$LogDirectory = '',
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 相対パスをスクリプト基準の絶対パスへ変換する
function Resolve-StartupPath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
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

# Windows Explorer が操作可能になるまで、上限時間内で待機する
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

# 設定ファイルとログ出力先を決定する
$resolvedSettingsPath = Resolve-StartupPath -Path $SettingsPath -DefaultPath (Join-Path $PSScriptRoot 'virtual-desktop-setting.json')
$resolvedLogDirectory = Resolve-StartupPath -Path $LogDirectory -DefaultPath (Join-Path $PSScriptRoot 'logs')
$null = New-Item -ItemType Directory -Path $resolvedLogDirectory -Force
$logFilePath = Join-Path $resolvedLogDirectory ("startup-virtual-desktop-{0}-{1}.jsonl" -f [datetime]::Now.ToString('yyyyMMdd-HHmmss'), $PID)

# 1 行 1 JSON 形式で実行ログを記録する
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

# 二重起動を防止する
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
        & $logger 'Warning' '別の仮想デスクトップ起動処理が既に実行中です。' $null
        Write-Warning '別の仮想デスクトップ起動処理が既に実行中のため、この処理を終了します。'
        $exitCode = 0
    } else {
        # 必要なモジュールと設定ファイルを読み込む
        $coreModulePath = Join-Path $PSScriptRoot 'modules\StartupVirtualDesktop.Core.psm1'
        $windowsModulePath = Join-Path $PSScriptRoot 'modules\StartupVirtualDesktop.Windows.psm1'
        Import-Module $coreModulePath -Force -ErrorAction Stop
        Import-Module $windowsModulePath -Force -ErrorAction Stop

        # 実行環境と VirtualDesktop モジュールのバージョンを確認する
        $diagnostics = Get-StartupEnvironmentDiagnostics
        & $logger 'Info' '起動環境を検出しました。' $diagnostics

        if (-not (Test-Path -LiteralPath $resolvedSettingsPath -PathType Leaf)) {
            throw "設定ファイル '$resolvedSettingsPath' が存在しません。"
        }

        $rawSettings = Get-Content -LiteralPath $resolvedSettingsPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $settings = ConvertTo-DesktopLayoutSettings -InputObject $rawSettings
        $null = Test-DesktopLayoutSettings -Settings $settings
        foreach ($warning in @($settings.warnings)) {
            & $logger 'Warning' $warning $null
            Write-Warning $warning
        }

        if ([string]::IsNullOrWhiteSpace($diagnostics.VirtualDesktopModuleVersion)) {
            & $logger 'Warning' 'VirtualDesktop モジュールがインストールされていません。' $null
        } else {
            $installedModuleVersion = [version]$diagnostics.VirtualDesktopModuleVersion
            if ($installedModuleVersion -lt [version]'1.5.11') {
                $versionWarning = "VirtualDesktop $installedModuleVersion がインストールされています。1.5.11 以降を推奨します。"
                & $logger 'Warning' $versionWarning $null
                Write-Warning $versionWarning
            }
        }

        # -ValidateOnly の場合は設定検証だけで終了する
        if ($ValidateOnly) {
            & $logger 'Info' '設定の検証に成功しました。' @{ settingsPath = $resolvedSettingsPath }
            Write-Output "設定の検証に成功しました: $resolvedSettingsPath"
            $exitCode = 0
        } else {
            if ([string]::IsNullOrWhiteSpace($diagnostics.VirtualDesktopModuleVersion) -or
                [version]$diagnostics.VirtualDesktopModuleVersion -lt [version]'1.5.9') {
                throw 'VirtualDesktop モジュール 1.5.9 以降が必要です。Install-Module VirtualDesktop -Scope CurrentUser を実行してください。'
            }

            Import-Module VirtualDesktop -MinimumVersion 1.5.9 -Force -ErrorAction Stop
            if (-not (Wait-ExplorerReady -TimeoutSeconds 30)) {
                throw 'Windows Explorer が 30 秒以内に起動しませんでした。'
            }

            # 仮想デスクトップとアプリケーションを配置する
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
            & $logger $(if ($failedCount -gt 0) { 'Error' } else { 'Info' }) 'デスクトップ配置処理が完了しました。' $summary
            Write-Output ("デスクトップ配置が完了しました: 全 {0} 件、失敗 {1} 件。ログ: {2}" -f $results.Count, $failedCount, $logFilePath)
            $exitCode = if ($failedCount -gt 0) { 1 } else { 0 }
        }
    }
} catch {
    # 例外をログへ記録し、終了前にリソースを解放する
    try {
        & $logger 'Error' '仮想デスクトップの起動処理に失敗しました。' @{ error = $_.Exception.Message }
    } catch {
        # ログ記録の失敗によって、元のエラーを隠さないようにする
    }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    $exitCode = 2
} finally {
    # 取得した Mutex を解放し、OS リソースを破棄する
    if ($ownsMutex -and $null -ne $mutex) {
        $mutex.ReleaseMutex()
    }
    if ($null -ne $mutex) {
        $mutex.Dispose()
    }
}

exit $exitCode
