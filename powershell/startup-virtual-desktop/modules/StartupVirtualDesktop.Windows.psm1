Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Request-NamedDesktop.psm1') -Force

function Initialize-StartupVirtualDesktopWindowApi {
    if ($null -ne ('StartupVirtualDesktop.NativeWindow' -as [type])) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace StartupVirtualDesktop
{
    public static class NativeWindow
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hwnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hwnd, uint command);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr hwnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int maxCount);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hwnd, StringBuilder className, int maxCount);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool ShowWindowAsync(IntPtr hwnd, int command);

        public static IntPtr[] EnumerateVisibleTopLevel()
        {
            const uint GW_OWNER = 4;
            var handles = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hwnd, IntPtr lParam)
            {
                if (IsWindowVisible(hwnd) && GetWindow(hwnd, GW_OWNER) == IntPtr.Zero)
                {
                    handles.Add(hwnd);
                }
                return true;
            }, IntPtr.Zero);
            return handles.ToArray();
        }

        public static string GetTitle(IntPtr hwnd)
        {
            int length = GetWindowTextLength(hwnd);
            var text = new StringBuilder(length + 1);
            GetWindowText(hwnd, text, text.Capacity);
            return text.ToString();
        }

        public static string GetClass(IntPtr hwnd)
        {
            var className = new StringBuilder(512);
            GetClassName(hwnd, className, className.Capacity);
            return className.ToString();
        }

        public static int GetProcessId(IntPtr hwnd)
        {
            uint processId;
            GetWindowThreadProcessId(hwnd, out processId);
            return unchecked((int)processId);
        }

        public static bool Maximize(IntPtr hwnd)
        {
            const int SW_MAXIMIZE = 3;
            return ShowWindowAsync(hwnd, SW_MAXIMIZE);
        }
    }
}
'@
}

function Get-VisibleTopLevelWindows {
    Initialize-StartupVirtualDesktopWindowApi
    $windows = [System.Collections.Generic.List[object]]::new()

    foreach ($handle in [StartupVirtualDesktop.NativeWindow]::EnumerateVisibleTopLevel()) {
        $processId = [StartupVirtualDesktop.NativeWindow]::GetProcessId($handle)
        if ($processId -le 0) {
            continue
        }

        try {
            $process = Get-Process -Id $processId -ErrorAction Stop
            $windows.Add([pscustomobject]@{
                Handle = [long]$handle
                ProcessId = $processId
                ProcessName = $process.ProcessName
                Title = [StartupVirtualDesktop.NativeWindow]::GetTitle($handle)
                ClassName = [StartupVirtualDesktop.NativeWindow]::GetClass($handle)
            })
        } catch {
            continue
        }
    }

    return $windows.ToArray()
}

function Get-DesktopShortcutMetadata {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $targetPath = [string]$shortcut.TargetPath

    return [pscustomobject]@{
        targetPath = $targetPath
        preferredTitle = [System.IO.Path]::GetFileNameWithoutExtension($Path)
        trackStartedProcess = -not [string]::IsNullOrWhiteSpace($targetPath)
    }
}

function Resolve-DesktopApplication {
    param(
        [Parameter(Mandatory)]
        [object]$App
    )

    $configuredPath = [Environment]::ExpandEnvironmentVariables([string]$App.path)
    $launchPath = $configuredPath
    $inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($configuredPath)
    $preferredTitle = ''
    $trackStartedProcess = $true

    if ([System.IO.Path]::GetExtension($configuredPath).Equals('.lnk', [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
        $shortcutMetadata = Get-DesktopShortcutMetadata -Path $configuredPath
        $preferredTitle = $shortcutMetadata.preferredTitle
        $trackStartedProcess = $shortcutMetadata.trackStartedProcess
        if (-not [string]::IsNullOrWhiteSpace($shortcutMetadata.targetPath)) {
            $inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($shortcutMetadata.targetPath)
        }
    } elseif (Test-Path -LiteralPath $configuredPath -PathType Leaf) {
        $launchPath = (Get-Item -LiteralPath $configuredPath -ErrorAction Stop).FullName
        $inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($launchPath)
    } else {
        $command = Get-Command -Name $configuredPath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) {
            $launchPath = $command.Source
            $inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($command.Source)
        }
    }

    return [pscustomobject]@{
        path = $App.path
        launchPath = $launchPath
        arguments = @($App.arguments)
        workingDirectory = $App.workingDirectory
        timeoutSeconds = $App.timeoutSeconds
        onExisting = $App.onExisting
        maximized = $App.maximized
        windowMatch = $App.windowMatch
        inferredProcessName = $inferredProcessName
        preferredTitle = $preferredTitle
        trackStartedProcess = $trackStartedProcess
        startedProcessId = 0
    }
}

function Start-DesktopApplication {
    param(
        [Parameter(Mandatory)]
        [object]$App
    )

    $options = @{
        FilePath = $App.launchPath
        ErrorAction = 'Stop'
    }
    $trackStartedProcess = if ($App.PSObject.Properties.Name -contains 'trackStartedProcess') {
        [bool]$App.trackStartedProcess
    } else {
        $true
    }
    if ($trackStartedProcess) {
        $options.PassThru = $true
    }
    if (@($App.arguments).Count -gt 0) {
        $options.ArgumentList = @($App.arguments)
    }
    if (-not [string]::IsNullOrWhiteSpace($App.workingDirectory)) {
        $options.WorkingDirectory = $App.workingDirectory
    }

    $process = Start-Process @options
    return [pscustomobject]@{
        ProcessId = if ($trackStartedProcess -and $null -ne $process) { $process.Id } else { 0 }
    }
}

function Get-StartupEnvironmentDiagnostics {
    [CmdletBinding()]
    param()

    $osVersion = [Environment]::OSVersion.Version
    $virtualDesktopModule = Get-Module -ListAvailable -Name VirtualDesktop |
        Sort-Object Version -Descending |
        Select-Object -First 1

    return [pscustomobject]@{
        OSVersion = $osVersion.ToString()
        OSBuild = [string]$osVersion.Build
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        VirtualDesktopModuleVersion = if ($null -ne $virtualDesktopModule) { $virtualDesktopModule.Version.ToString() } else { '' }
    }
}

function New-WindowsDesktopAdapter {
    [CmdletBinding()]
    param()

    Initialize-StartupVirtualDesktopWindowApi

    return [pscustomobject]@{
        GetOrCreateDesktop = {
            param($Name)
            Request-NamedDesktop -Name $Name
        }
        SetWallpaper = {
            param($Desktop, $Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw "Wallpaper file '$Path' does not exist."
            }
            Set-DesktopWallpaper -Desktop $Desktop -Path $Path -ErrorAction Stop
        }
        ResolveApplication = {
            param($App)
            Resolve-DesktopApplication -App $App
        }
        GetWindows = {
            Get-VisibleTopLevelWindows
        }
        StartApplication = {
            param($App)
            Start-DesktopApplication -App $App
        }
        MoveWindow = {
            param($Desktop, $Window)
            Move-Window -Desktop $Desktop -Hwnd ([IntPtr][long]$Window.Handle) -ErrorAction Stop | Out-Null
        }
        TestWindow = {
            param($Desktop, $Window)
            Test-Window -Desktop $Desktop -Hwnd ([IntPtr][long]$Window.Handle) -ErrorAction Stop
        }
        MaximizeWindow = {
            param($Window)
            [StartupVirtualDesktop.NativeWindow]::Maximize([IntPtr][long]$Window.Handle)
        }
        GetUtcNow = {
            [datetime]::UtcNow
        }
        Wait = {
            param($Milliseconds)
            Start-Sleep -Milliseconds $Milliseconds
        }
    }
}

Export-ModuleMember -Function @(
    'New-WindowsDesktopAdapter',
    'Get-StartupEnvironmentDiagnostics'
)
