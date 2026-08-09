$modulePath = Join-Path $PSScriptRoot '..\modules\StartupVirtualDesktop.Windows.psm1'
Import-Module $modulePath -Force

function New-WindowsTestApp {
    param(
        [string]$Path,
        [string[]]$Arguments = @()
    )

    [pscustomobject]@{
        path = $Path
        arguments = $Arguments
        workingDirectory = ''
        timeoutSeconds = 30
        onExisting = 'Move'
        maximized = $false
        windowMatch = $null
    }
}

Describe 'New-WindowsDesktopAdapter' {
    It 'provides every operation required by the core' {
        $adapter = New-WindowsDesktopAdapter
        $requiredOperations = @(
            'GetOrCreateDesktop',
            'SetWallpaper',
            'ResolveApplication',
            'GetWindows',
            'StartApplication',
            'MoveWindow',
            'TestWindow',
            'MaximizeWindow',
            'GetUtcNow',
            'Wait'
        )

        foreach ($operation in $requiredOperations) {
            ($adapter.PSObject.Properties.Name -contains $operation) | Should Be $true
            $adapter.$operation.GetType().FullName | Should Be 'System.Management.Automation.ScriptBlock'
        }
    }

    It 'resolves an application command to an inferred process name' {
        $adapter = New-WindowsDesktopAdapter
        $resolveApplication = $adapter.ResolveApplication

        $resolved = & $resolveApplication (New-WindowsTestApp -Path 'cmd')

        $resolved.inferredProcessName | Should Be 'cmd'
        (Test-Path -LiteralPath $resolved.launchPath -PathType Leaf) | Should Be $true
    }

    It 'resolves a shortcut target and preferred title' {
        $shortcutPath = Join-Path $TestDrive 'My App.lnk'
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = "$env:WINDIR\System32\notepad.exe"
        $shortcut.Save()
        $adapter = New-WindowsDesktopAdapter
        $resolveApplication = $adapter.ResolveApplication

        $resolved = & $resolveApplication (New-WindowsTestApp -Path $shortcutPath)

        $resolved.inferredProcessName | Should Be 'notepad'
        $resolved.preferredTitle | Should Be 'My App'
        $resolved.launchPath | Should Be $shortcutPath
    }

    It 'enumerates visible top-level windows without mutating them' {
        $adapter = New-WindowsDesktopAdapter
        $getWindows = $adapter.GetWindows

        $windows = @(& $getWindows)

        $windows.Count | Should BeGreaterThan -1
        if ($windows.Count -gt 0) {
            ($windows[0].PSObject.Properties.Name -contains 'Handle') | Should Be $true
            ($windows[0].PSObject.Properties.Name -contains 'ProcessName') | Should Be $true
            ($windows[0].PSObject.Properties.Name -contains 'Title') | Should Be $true
            ($windows[0].PSObject.Properties.Name -contains 'ClassName') | Should Be $true
        }
    }
}

Describe 'Get-StartupEnvironmentDiagnostics' {
    It 'reports the runtime and module versions' {
        $diagnostics = Get-StartupEnvironmentDiagnostics

        [string]::IsNullOrWhiteSpace($diagnostics.OSVersion) | Should Be $false
        [string]::IsNullOrWhiteSpace($diagnostics.OSBuild) | Should Be $false
        [string]::IsNullOrWhiteSpace($diagnostics.PowerShellVersion) | Should Be $false
        ($diagnostics.PSObject.Properties.Name -contains 'VirtualDesktopModuleVersion') | Should Be $true
    }
}
