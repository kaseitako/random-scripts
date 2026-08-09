Set-StrictMode -Version Latest

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne $InputObject -and $null -ne $InputObject.PSObject.Properties[$Name]
}

function ConvertTo-DesktopLayoutSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [AllowNull()]
        [object]$InputObject
    )

    $warnings = [System.Collections.Generic.List[string]]::new()
    $normalizedDesktops = [System.Collections.Generic.List[object]]::new()
    $inputDesktops = if (Test-ObjectProperty -InputObject $InputObject -Name 'desktops') {
        @($InputObject.desktops)
    } else {
        @()
    }

    foreach ($desktop in $inputDesktops) {
        if (Test-ObjectProperty -InputObject $desktop -Name 'waitSeconds') {
            $warnings.Add("Desktop '$($desktop.name)' uses deprecated waitSeconds; the value is ignored.")
        }

        $normalizedApps = [System.Collections.Generic.List[object]]::new()
        $inputApps = if (Test-ObjectProperty -InputObject $desktop -Name 'apps') {
            @($desktop.apps)
        } else {
            @()
        }

        foreach ($app in $inputApps) {
            $maximized = if (Test-ObjectProperty -InputObject $app -Name 'maximized') {
                [bool]$app.maximized
            } elseif (Test-ObjectProperty -InputObject $app -Name 'fullscreen') {
                [bool]$app.fullscreen
            } else {
                $false
            }

            $normalizedApps.Add([pscustomobject]@{
                path = if (Test-ObjectProperty -InputObject $app -Name 'path') { [string]$app.path } else { '' }
                arguments = if (Test-ObjectProperty -InputObject $app -Name 'arguments') { @($app.arguments) } else { @() }
                workingDirectory = if (Test-ObjectProperty -InputObject $app -Name 'workingDirectory') { [string]$app.workingDirectory } else { '' }
                timeoutSeconds = if (Test-ObjectProperty -InputObject $app -Name 'timeoutSeconds') { [int]$app.timeoutSeconds } else { 30 }
                onExisting = if (Test-ObjectProperty -InputObject $app -Name 'onExisting') { [string]$app.onExisting } else { 'Move' }
                maximized = $maximized
                windowMatch = if (Test-ObjectProperty -InputObject $app -Name 'windowMatch') { $app.windowMatch } else { $null }
            })
        }

        $normalizedDesktops.Add([pscustomobject]@{
            name = if (Test-ObjectProperty -InputObject $desktop -Name 'name') { [string]$desktop.name } else { '' }
            apps = $normalizedApps.ToArray()
            wallpaperAbsolutePath = if (Test-ObjectProperty -InputObject $desktop -Name 'wallpaperAbsolutePath') {
                [string]$desktop.wallpaperAbsolutePath
            } else {
                ''
            }
        })
    }

    return [pscustomobject]@{
        desktops = $normalizedDesktops.ToArray()
        warnings = $warnings.ToArray()
    }
}

function Test-DesktopLayoutSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Settings
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $desktopNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($desktop in @($Settings.desktops)) {
        if ([string]::IsNullOrWhiteSpace($desktop.name)) {
            $errors.Add('Desktop name must not be empty.')
        } elseif (-not $desktopNames.Add($desktop.name)) {
            $errors.Add("Duplicate desktop name '$($desktop.name)'.")
        }

        foreach ($app in @($desktop.apps)) {
            if ([string]::IsNullOrWhiteSpace($app.path)) {
                $errors.Add("Application path on desktop '$($desktop.name)' must not be empty.")
            }

            if ($app.timeoutSeconds -lt 1 -or $app.timeoutSeconds -gt 300) {
                $errors.Add("Application '$($app.path)' timeoutSeconds must be between 1 and 300.")
            }

            if ($app.onExisting -notin @('Move', 'Skip', 'Launch')) {
                $errors.Add("Application '$($app.path)' onExisting must be Move, Skip, or Launch.")
            }

            if ($null -ne $app.windowMatch) {
                foreach ($regexProperty in @('titleRegex', 'classNameRegex')) {
                    if (Test-ObjectProperty -InputObject $app.windowMatch -Name $regexProperty) {
                        try {
                            $null = [regex]::new([string]$app.windowMatch.$regexProperty)
                        } catch {
                            $errors.Add("Application '$($app.path)' $regexProperty is not a valid regular expression: $($_.Exception.Message)")
                        }
                    }
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw [System.ArgumentException]::new(($errors -join [Environment]::NewLine))
    }

    return $true
}

function Test-HandleInSet {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Set,

        [Parameter(Mandatory)]
        [long]$Handle
    )

    return $Set.ContainsKey($Handle) -or
        $Set.ContainsKey([int]$Handle) -or
        $Set.ContainsKey([string]$Handle)
}

function Get-WindowMatchScore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Window,

        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [hashtable]$NewHandles,

        [Parameter(Mandatory)]
        [hashtable]$ExcludedHandles
    )

    $handle = [long]$Window.Handle
    if (Test-HandleInSet -Set $ExcludedHandles -Handle $handle) {
        return -1
    }

    $score = 0
    $hasExplicitMatch = $false
    if ($null -ne $App.windowMatch) {
        if (Test-ObjectProperty -InputObject $App.windowMatch -Name 'processName') {
            $hasExplicitMatch = $true
            if (-not ([string]$Window.ProcessName).Equals([string]$App.windowMatch.processName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return -1
            }
        }

        if (Test-ObjectProperty -InputObject $App.windowMatch -Name 'titleRegex') {
            $hasExplicitMatch = $true
            if ([string]$Window.Title -notmatch [string]$App.windowMatch.titleRegex) {
                return -1
            }
        }

        if (Test-ObjectProperty -InputObject $App.windowMatch -Name 'classNameRegex') {
            $hasExplicitMatch = $true
            if ([string]$Window.ClassName -notmatch [string]$App.windowMatch.classNameRegex) {
                return -1
            }
        }
    }

    if ($hasExplicitMatch) {
        $score += 100
    } else {
        $inferredProcessName = if (Test-ObjectProperty -InputObject $App -Name 'inferredProcessName') {
            [string]$App.inferredProcessName
        } else {
            ''
        }

        if (-not [string]::IsNullOrWhiteSpace($inferredProcessName)) {
            if (-not ([string]$Window.ProcessName).Equals($inferredProcessName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return -1
            }
            $score += 40
        }

        $preferredTitle = if (Test-ObjectProperty -InputObject $App -Name 'preferredTitle') {
            [string]$App.preferredTitle
        } else {
            ''
        }
        if (-not [string]::IsNullOrWhiteSpace($preferredTitle) -and
            [string]$Window.Title -like "*$preferredTitle*") {
            $score += 20
        }

        $startedProcessId = if (Test-ObjectProperty -InputObject $App -Name 'startedProcessId') {
            [int]$App.startedProcessId
        } else {
            0
        }
        if ($startedProcessId -gt 0 -and [int]$Window.ProcessId -eq $startedProcessId) {
            $score += 30
        }
    }

    if (Test-HandleInSet -Set $NewHandles -Handle $handle) {
        $score += 50
    }

    if ($score -eq 0) {
        return -1
    }

    return $score
}

function Wait-ApplicationWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [object]$Adapter,

        [Parameter(Mandatory)]
        [hashtable]$BeforeHandles,

        [Parameter(Mandatory)]
        [hashtable]$ExcludedHandles
    )

    $getWindows = $Adapter.GetWindows
    $getUtcNow = $Adapter.GetUtcNow
    $wait = $Adapter.Wait
    $deadline = (& $getUtcNow).AddSeconds([double]$App.timeoutSeconds)

    while ($true) {
        $newHandles = @{}
        $bestWindow = $null
        $bestScore = -1

        foreach ($window in @(& $getWindows)) {
            $handle = [long]$window.Handle
            if (-not (Test-HandleInSet -Set $BeforeHandles -Handle $handle)) {
                $newHandles[[string]$handle] = $true
            }

            $score = Get-WindowMatchScore -Window $window -App $App -NewHandles $newHandles -ExcludedHandles $ExcludedHandles
            if ($score -gt $bestScore -or
                ($score -eq $bestScore -and $null -ne $bestWindow -and $handle -lt [long]$bestWindow.Handle)) {
                $bestScore = $score
                $bestWindow = $window
            }
        }

        if ($null -ne $bestWindow -and $bestScore -ge 0) {
            return $bestWindow
        }

        if ((& $getUtcNow) -ge $deadline) {
            return $null
        }

        & $wait 200
    }
}

function Get-BestApplicationWindow {
    param(
        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [object[]]$Windows,

        [Parameter(Mandatory)]
        [hashtable]$ExcludedHandles
    )

    $bestWindow = $null
    $bestScore = -1
    foreach ($window in $Windows) {
        $score = Get-WindowMatchScore -Window $window -App $App -NewHandles @{} -ExcludedHandles $ExcludedHandles
        $handle = [long]$window.Handle
        if ($score -gt $bestScore -or
            ($score -eq $bestScore -and $score -ge 0 -and $null -ne $bestWindow -and $handle -lt [long]$bestWindow.Handle)) {
            $bestScore = $score
            $bestWindow = $window
        }
    }

    if ($bestScore -lt 0) {
        return $null
    }

    return $bestWindow
}

function New-ApplicationResult {
    param(
        [Parameter(Mandatory)]
        [string]$DesktopName,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Status,

        [long]$Handle = 0,

        [string]$ProcessName = '',

        [long]$ElapsedMilliseconds = 0,

        [string]$Error = ''
    )

    return [pscustomobject]@{
        DesktopName = $DesktopName
        Path = $Path
        Status = $Status
        Handle = $Handle
        ProcessName = $ProcessName
        ElapsedMilliseconds = $ElapsedMilliseconds
        Error = $Error
    }
}

function Write-DesktopLayoutLog {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Log,

        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message,

        [AllowNull()]
        [object]$Data
    )

    try {
        & $Log $Level $Message $Data
    } catch {
        Write-Warning "Layout logger failed: $($_.Exception.Message)"
    }
}

function Invoke-DesktopLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Settings,

        [Parameter(Mandatory)]
        [object]$Adapter,

        [Parameter(Mandatory)]
        [scriptblock]$Log
    )

    $null = Test-DesktopLayoutSettings -Settings $Settings
    $results = [System.Collections.Generic.List[object]]::new()
    $assignedHandles = @{}
    $desktopsByName = @{}
    $desktopErrors = @{}
    $getUtcNow = $Adapter.GetUtcNow
    $getOrCreateDesktop = $Adapter.GetOrCreateDesktop
    $setWallpaper = $Adapter.SetWallpaper
    $resolveApplication = $Adapter.ResolveApplication
    $getWindows = $Adapter.GetWindows
    $startApplication = $Adapter.StartApplication
    $moveWindow = $Adapter.MoveWindow
    $testWindow = $Adapter.TestWindow
    $maximizeWindow = $Adapter.MaximizeWindow

    foreach ($desktop in @($Settings.desktops)) {
        try {
            $desktopObject = & $getOrCreateDesktop $desktop.name
            $desktopsByName[$desktop.name] = $desktopObject
            Write-DesktopLayoutLog -Log $Log -Level 'Info' -Message 'Desktop ready.' -Data @{
                desktopName = $desktop.name
            }
        } catch {
            $desktopErrors[$desktop.name] = $_.Exception.Message
            Write-DesktopLayoutLog -Log $Log -Level 'Error' -Message 'Desktop creation failed.' -Data @{
                desktopName = $desktop.name
                error = $_.Exception.Message
            }
        }
    }

    foreach ($desktop in @($Settings.desktops)) {
        if ($desktopErrors.ContainsKey($desktop.name)) {
            foreach ($app in @($desktop.apps)) {
                $results.Add((New-ApplicationResult -DesktopName $desktop.name -Path $app.path -Status 'Failed' -Error "Desktop creation failed: $($desktopErrors[$desktop.name])"))
            }
            continue
        }

        $targetDesktop = $desktopsByName[$desktop.name]
        if (-not [string]::IsNullOrWhiteSpace($desktop.wallpaperAbsolutePath)) {
            try {
                $null = & $setWallpaper $targetDesktop $desktop.wallpaperAbsolutePath
            } catch {
                Write-DesktopLayoutLog -Log $Log -Level 'Warning' -Message 'Wallpaper update failed.' -Data @{
                    desktopName = $desktop.name
                    path = $desktop.wallpaperAbsolutePath
                    error = $_.Exception.Message
                }
            }
        }

        foreach ($configuredApp in @($desktop.apps)) {
            $startedAt = & $getUtcNow
            $window = $null
            try {
                $app = & $resolveApplication $configuredApp
                $windowsBeforeLaunch = @(& $getWindows)
                $existingWindow = $null
                if ($app.onExisting -ne 'Launch') {
                    $existingWindow = Get-BestApplicationWindow -App $app -Windows $windowsBeforeLaunch -ExcludedHandles $assignedHandles
                }

                if ($null -ne $existingWindow) {
                    $window = $existingWindow
                    $assignedHandles[[string][long]$window.Handle] = $true
                    if ($app.onExisting -eq 'Skip') {
                        $elapsed = [long]((& $getUtcNow) - $startedAt).TotalMilliseconds
                        $result = New-ApplicationResult -DesktopName $desktop.name -Path $app.path -Status 'Skipped' -Handle ([long]$window.Handle) -ProcessName ([string]$window.ProcessName) -ElapsedMilliseconds $elapsed
                        $results.Add($result)
                        Write-DesktopLayoutLog -Log $Log -Level 'Info' -Message 'Existing application window skipped.' -Data $result
                        continue
                    }
                } else {
                    $beforeHandles = @{}
                    foreach ($beforeWindow in $windowsBeforeLaunch) {
                        $beforeHandles[[string][long]$beforeWindow.Handle] = $true
                    }

                    $launchInfo = & $startApplication $app
                    if ($null -ne $launchInfo -and $null -ne $launchInfo.PSObject.Properties['ProcessId']) {
                        if ($null -ne $app.PSObject.Properties['startedProcessId']) {
                            $app.startedProcessId = [int]$launchInfo.ProcessId
                        } else {
                            $app | Add-Member -NotePropertyName startedProcessId -NotePropertyValue ([int]$launchInfo.ProcessId)
                        }
                    }

                    $window = Wait-ApplicationWindow -App $app -Adapter $Adapter -BeforeHandles $beforeHandles -ExcludedHandles $assignedHandles
                    if ($null -eq $window) {
                        throw "Timed out after $($app.timeoutSeconds) seconds waiting for an application window."
                    }
                    $assignedHandles[[string][long]$window.Handle] = $true
                }

                $status = 'AlreadyPlaced'
                if (-not (& $testWindow $targetDesktop $window)) {
                    $null = & $moveWindow $targetDesktop $window
                    if (-not (& $testWindow $targetDesktop $window)) {
                        throw 'Window movement verification failed.'
                    }
                    $status = 'Moved'
                }

                if ($app.maximized) {
                    $null = & $maximizeWindow $window
                }

                $elapsed = [long]((& $getUtcNow) - $startedAt).TotalMilliseconds
                $result = New-ApplicationResult -DesktopName $desktop.name -Path $app.path -Status $status -Handle ([long]$window.Handle) -ProcessName ([string]$window.ProcessName) -ElapsedMilliseconds $elapsed
                $results.Add($result)
                Write-DesktopLayoutLog -Log $Log -Level 'Info' -Message 'Application reconciled.' -Data $result
            } catch {
                $elapsed = [long]((& $getUtcNow) - $startedAt).TotalMilliseconds
                $handle = if ($null -ne $window) { [long]$window.Handle } else { 0 }
                $processName = if ($null -ne $window) { [string]$window.ProcessName } else { '' }
                $result = New-ApplicationResult -DesktopName $desktop.name -Path $configuredApp.path -Status 'Failed' -Handle $handle -ProcessName $processName -ElapsedMilliseconds $elapsed -Error $_.Exception.Message
                $results.Add($result)
                Write-DesktopLayoutLog -Log $Log -Level 'Error' -Message 'Application reconciliation failed.' -Data $result
            }
        }
    }

    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'ConvertTo-DesktopLayoutSettings',
    'Test-DesktopLayoutSettings',
    'Get-WindowMatchScore',
    'Wait-ApplicationWindow',
    'Invoke-DesktopLayout'
)
