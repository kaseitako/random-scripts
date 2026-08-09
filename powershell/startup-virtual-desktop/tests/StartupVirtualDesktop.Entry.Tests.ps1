$projectPath = Split-Path $PSScriptRoot -Parent
$scriptPath = Join-Path $projectPath 'Startup-VirtualDesktop.ps1'
$samplePath = Join-Path $projectPath 'virtual-desktop-setting.sample.json'

function Invoke-EntryScriptProcess {
    param(
        [string]$SettingsPath,
        [string]$LogDirectory
    )

    $id = [guid]::NewGuid().ToString('N')
    $standardOutput = Join-Path $TestDrive "$id.stdout.txt"
    $standardError = Join-Path $TestDrive "$id.stderr.txt"
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $script:scriptPath,
        '-SettingsPath', $SettingsPath,
        '-LogDirectory', $LogDirectory,
        '-ValidateOnly'
    )
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $standardOutput -RedirectStandardError $standardError

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = ((Get-Content -LiteralPath $standardOutput -Raw -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $standardError -Raw -ErrorAction SilentlyContinue))
    }
}

Describe 'Startup-VirtualDesktop.ps1' {
    It 'has no PowerShell parser errors' {
        $tokens = $null
        $errors = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)

        $errors.Count | Should Be 0
    }

    It 'validates settings from a different current directory' {
        $logDirectory = Join-Path $TestDrive 'logs'
        $result = Invoke-EntryScriptProcess -SettingsPath $samplePath -LogDirectory $logDirectory

        $result.ExitCode | Should Be 0
        $result.Output | Should Match 'validation succeeded'
        $logFiles = @(Get-ChildItem -LiteralPath $logDirectory -Filter '*.jsonl')
        $logFiles.Count | Should Be 1
        foreach ($line in Get-Content -LiteralPath $logFiles[0].FullName) {
            { $line | ConvertFrom-Json -ErrorAction Stop } | Should Not Throw
        }
    }

    It 'fails validation for a missing settings file' {
        $missingPath = Join-Path $TestDrive 'missing.json'
        $logDirectory = Join-Path $TestDrive 'missing-logs'

        $result = Invoke-EntryScriptProcess -SettingsPath $missingPath -LogDirectory $logDirectory

        $result.ExitCode | Should Not Be 0
    }

    It 'does not contain the old fixed shutdown delay' {
        $content = Get-Content -LiteralPath $scriptPath -Raw

        $content | Should Not Match 'Start-Sleep\s+10'
        $content | Should Not Match '10秒後'
    }
}
