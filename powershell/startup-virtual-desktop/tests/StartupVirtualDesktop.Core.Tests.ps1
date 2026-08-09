$modulePath = Join-Path $PSScriptRoot '..\modules\StartupVirtualDesktop.Core.psm1'
Import-Module $modulePath -Force

function New-TestLayout {
    param(
        [object[]]$Desktops
    )

    [pscustomobject]@{ desktops = $Desktops }
}

Describe 'ConvertTo-DesktopLayoutSettings' {
    It 'normalizes legacy application settings' {
        $inputSettings = New-TestLayout @(
            [pscustomobject]@{
                name = 'Main'
                waitSeconds = 10
                apps = @(
                    [pscustomobject]@{
                        path = 'chrome'
                        fullscreen = $true
                    }
                )
            }
        )

        $result = ConvertTo-DesktopLayoutSettings -InputObject $inputSettings
        $app = $result.desktops[0].apps[0]

        $app.maximized | Should Be $true
        $app.timeoutSeconds | Should Be 30
        $app.onExisting | Should Be 'Move'
        @($app.arguments).Count | Should Be 0
        $result.warnings.Count | Should Be 1
        $result.warnings[0] | Should Match 'waitSeconds'
    }

    It 'prefers maximized over the fullscreen compatibility alias' {
        $inputSettings = New-TestLayout @(
            [pscustomobject]@{
                name = 'Main'
                apps = @(
                    [pscustomobject]@{
                        path = 'notepad'
                        fullscreen = $true
                        maximized = $false
                    }
                )
            }
        )

        $result = ConvertTo-DesktopLayoutSettings -InputObject $inputSettings

        $result.desktops[0].apps[0].maximized | Should Be $false
    }
}

Describe 'Test-DesktopLayoutSettings' {
    It 'rejects duplicate desktop names' {
        $settings = ConvertTo-DesktopLayoutSettings -InputObject (New-TestLayout @(
            [pscustomobject]@{ name = 'Main'; apps = @() },
            [pscustomobject]@{ name = 'Main'; apps = @() }
        ))

        $message = try {
            Test-DesktopLayoutSettings -Settings $settings
            ''
        } catch {
            $_.Exception.Message
        }

        $message | Should Match 'Duplicate desktop name'
    }

    It 'rejects a timeout outside the supported range' {
        $settings = ConvertTo-DesktopLayoutSettings -InputObject (New-TestLayout @(
            [pscustomobject]@{
                name = 'Main'
                apps = @([pscustomobject]@{ path = 'notepad'; timeoutSeconds = 301 })
            }
        ))

        $message = try {
            Test-DesktopLayoutSettings -Settings $settings
            ''
        } catch {
            $_.Exception.Message
        }

        $message | Should Match 'timeoutSeconds'
    }

    It 'rejects an invalid title regular expression' {
        $settings = ConvertTo-DesktopLayoutSettings -InputObject (New-TestLayout @(
            [pscustomobject]@{
                name = 'Main'
                apps = @([pscustomobject]@{
                    path = 'notepad'
                    windowMatch = [pscustomobject]@{ titleRegex = '[' }
                })
            }
        ))

        $message = try {
            Test-DesktopLayoutSettings -Settings $settings
            ''
        } catch {
            $_.Exception.Message
        }

        $message | Should Match 'titleRegex'
    }

    It 'accepts an empty desktop list' {
        $settings = ConvertTo-DesktopLayoutSettings -InputObject (New-TestLayout @())

        Test-DesktopLayoutSettings -Settings $settings
    }
}

Describe 'Get-WindowMatchScore' {
    BeforeEach {
        $script:window = [pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'chrome'
            Title = 'SoundCloud'
            ClassName = 'Chrome_WidgetWin_1'
        }
        $script:app = [pscustomobject]@{
            timeoutSeconds = 1
            inferredProcessName = 'chrome'
            preferredTitle = ''
            startedProcessId = 0
            windowMatch = $null
        }
    }

    It 'requires every explicit match field' {
        $script:app.windowMatch = [pscustomobject]@{
            processName = 'chrome'
            titleRegex = '^SoundCloud$'
            classNameRegex = '^Chrome_WidgetWin_1$'
        }

        Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{} -ExcludedHandles @{} | Should BeGreaterThan 0

        $script:window.Title = 'Different'
        Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{} -ExcludedHandles @{} | Should Be -1
    }

    It 'prefers a new matching process window' {
        $existing = [pscustomobject]@{
            Handle = [long]7; ProcessId = 70; ProcessName = 'chrome'; Title = 'Chrome'; ClassName = 'Chrome_WidgetWin_1'
        }

        $newScore = Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{ 42 = $true } -ExcludedHandles @{}
        $existingScore = Get-WindowMatchScore -Window $existing -App $script:app -NewHandles @{ 42 = $true } -ExcludedHandles @{}

        $newScore | Should BeGreaterThan $existingScore
    }

    It 'rejects a previously assigned handle' {
        Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{} -ExcludedHandles @{ 42 = $true } | Should Be -1
    }
}

Describe 'Wait-ApplicationWindow' {
    BeforeEach {
        $script:window = [pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'notepad'
            Title = 'Untitled - Notepad'
            ClassName = 'Notepad'
        }
        $script:app = [pscustomobject]@{
            timeoutSeconds = 1
            inferredProcessName = 'notepad'
            preferredTitle = ''
            startedProcessId = 100
            windowMatch = $null
        }
    }

    It 'returns a matching window after it appears' {
        $script:calls = 0
        $script:now = [datetime]'2026-08-09T00:00:00Z'
        $adapter = [pscustomobject]@{
            GetWindows = {
                $script:calls++
                if ($script:calls -lt 3) { @() } else { @($script:window) }
            }
            GetUtcNow = { $script:now }
            Wait = { param($Milliseconds) $script:now = $script:now.AddMilliseconds($Milliseconds) }
        }

        $result = Wait-ApplicationWindow -App $script:app -Adapter $adapter -BeforeHandles @{} -ExcludedHandles @{}

        $result.Handle | Should Be 42
    }

    It 'returns null when the timeout expires' {
        $script:now = [datetime]'2026-08-09T00:00:00Z'
        $adapter = [pscustomobject]@{
            GetWindows = { @() }
            GetUtcNow = { $script:now }
            Wait = { param($Milliseconds) $script:now = $script:now.AddMilliseconds($Milliseconds) }
        }

        $result = Wait-ApplicationWindow -App $script:app -Adapter $adapter -BeforeHandles @{} -ExcludedHandles @{}

        $result | Should BeNullOrEmpty
    }
}
