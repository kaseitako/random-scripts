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

Export-ModuleMember -Function @(
    'ConvertTo-DesktopLayoutSettings',
    'Test-DesktopLayoutSettings'
)
