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

    It 'allows a new launcher window whose process name differs' {
        $script:app.inferredProcessName = 'LineLauncher'
        $script:window.ProcessName = 'LINE'

        $newScore = Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{ 42 = $true } -ExcludedHandles @{}

        $newScore | Should BeGreaterThan 0
    }

    It 'rejects an existing window whose process name differs' {
        $script:app.inferredProcessName = 'LineLauncher'
        $script:window.ProcessName = 'LINE'

        Get-WindowMatchScore -Window $script:window -App $script:app -NewHandles @{} -ExcludedHandles @{} | Should Be -1
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

function New-OrchestrationSettings {
    param(
        [object[]]$Apps
    )

    ConvertTo-DesktopLayoutSettings -InputObject ([pscustomobject]@{
        desktops = @([pscustomobject]@{
            name = 'Main'
            wallpaperAbsolutePath = ''
            apps = $Apps
        })
    })
}

function New-ResolvedTestApp {
    param(
        [object]$App
    )

    [pscustomobject]@{
        path = $App.path
        arguments = @($App.arguments)
        workingDirectory = $App.workingDirectory
        timeoutSeconds = $App.timeoutSeconds
        onExisting = $App.onExisting
        maximized = $App.maximized
        windowMatch = $App.windowMatch
        inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($App.path)
        preferredTitle = ''
        startedProcessId = 0
    }
}

Describe 'Invoke-DesktopLayout' {
    BeforeEach {
        $script:now = [datetime]'2026-08-09T00:00:00Z'
        $script:windows = @()
        $script:startCount = 0
        $script:moveCount = 0
        $script:maximizeCount = 0
        $script:targetDesktop = [pscustomobject]@{ Name = 'Main'; Id = 'desktop-main' }

        $script:adapter = [pscustomobject]@{
            GetOrCreateDesktop = { param($Name) $script:targetDesktop }
            SetWallpaper = { param($Desktop, $Path) }
            ResolveApplication = { param($App) New-ResolvedTestApp -App $App }
            GetWindows = { @($script:windows) }
            StartApplication = {
                param($App)
                $script:startCount++
                [pscustomobject]@{ ProcessId = 0 }
            }
            MoveWindow = {
                param($Desktop, $Window)
                $script:moveCount++
                $Window.Desktop = $Desktop.Name
            }
            TestWindow = { param($Desktop, $Window) $Window.Desktop -eq $Desktop.Name }
            MaximizeWindow = {
                param($Window)
                $script:maximizeCount++
                $Window.Maximized = $true
            }
            GetUtcNow = { $script:now }
            Wait = { param($Milliseconds) $script:now = $script:now.AddMilliseconds($Milliseconds) }
        }
    }

    It 'moves and verifies an existing matching window without launching' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'notepad'
            Title = 'Untitled - Notepad'
            ClassName = 'Notepad'
            Desktop = 'Other'
            Maximized = $false
        })
        $settings = New-OrchestrationSettings @([pscustomobject]@{ path = 'notepad'; maximized = $true })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results.Count | Should Be 1
        $results[0].Status | Should Be 'Moved'
        $results[0].Handle | Should Be 42
        $script:windows[0].Desktop | Should Be 'Main'
        $script:windows[0].Maximized | Should Be $true
        $script:startCount | Should Be 0
        $script:moveCount | Should Be 1
        $script:maximizeCount | Should Be 1
    }

    It 'reports an already placed matching window' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Main'; Maximized = $false
        })
        $settings = New-OrchestrationSettings @([pscustomobject]@{ path = 'notepad' })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'AlreadyPlaced'
        $script:moveCount | Should Be 0
        $script:startCount | Should Be 0
    }

    It 'launches and selects the newly appearing window' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]7; ProcessId = 70; ProcessName = 'notepad'; Title = 'Old'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
        })
        $script:adapter.StartApplication = {
            param($App)
            $script:startCount++
            $script:windows += [pscustomobject]@{
                Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'New'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
            }
            [pscustomobject]@{ ProcessId = 100 }
        }
        $settings = New-OrchestrationSettings @([pscustomobject]@{ path = 'notepad'; onExisting = 'Launch' })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'Moved'
        $results[0].Handle | Should Be 42
        $script:startCount | Should Be 1
    }

    It 'returns failed when movement cannot be verified' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
        })
        $script:adapter.MoveWindow = { param($Desktop, $Window) $script:moveCount++ }
        $settings = New-OrchestrationSettings @([pscustomobject]@{ path = 'notepad' })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'Failed'
        $results[0].Error | Should Match 'verification'
    }

    It 'continues after an application timeout' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
        })
        $settings = New-OrchestrationSettings @(
            [pscustomobject]@{ path = 'missing'; timeoutSeconds = 1 },
            [pscustomobject]@{ path = 'notepad'; timeoutSeconds = 1 }
        )

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results.Count | Should Be 2
        $results[0].Status | Should Be 'Failed'
        $results[0].Error | Should Match 'Timed out'
        $results[1].Status | Should Be 'Moved'
    }

    It 'does not assign one handle to two application entries' {
        $script:windows = @(
            [pscustomobject]@{ Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'First'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false },
            [pscustomobject]@{ Handle = [long]43; ProcessId = 101; ProcessName = 'notepad'; Title = 'Second'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false }
        )
        $settings = New-OrchestrationSettings @(
            [pscustomobject]@{ path = 'notepad' },
            [pscustomobject]@{ path = 'notepad' }
        )

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results.Count | Should Be 2
        $results[0].Handle | Should Be 42
        $results[1].Handle | Should Be 43
    }

    It 'reacquires a replacement window when the selected handle becomes invalid' {
        $oldWindow = [pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'LINE'
            Title = 'LINE'
            ClassName = 'Chrome_WidgetWin_1'
            Desktop = 'Other'
            Maximized = $false
        }
        $script:replacementWindow = [pscustomobject]@{
            Handle = [long]43
            ProcessId = 100
            ProcessName = 'LINE'
            Title = 'LINE'
            ClassName = 'Chrome_WidgetWin_1'
            Desktop = 'Other'
            Maximized = $false
        }
        $script:windows = @($oldWindow)
        $script:waitCount = 0
        $script:logEntries = [System.Collections.Generic.List[object]]::new()
        $script:adapter.TestWindow = {
            param($Desktop, $Window)
            if ([long]$Window.Handle -eq 42) {
                $script:windows = @($script:replacementWindow)
                throw [System.InvalidOperationException]::new('TYPE_E_ELEMENTNOTFOUND')
            }
            $Window.Desktop -eq $Desktop.Name
        }
        $script:adapter.Wait = {
            param($Milliseconds)
            $script:waitCount++
            $script:now = $script:now.AddMilliseconds($Milliseconds)
        }
        $settings = New-OrchestrationSettings @([pscustomobject]@{
            path = 'LINE'
            windowMatch = [pscustomobject]@{
                processName = 'LINE'
                titleRegex = '^LINE$'
            }
        })
        $log = {
            param($Level, $Message, $Data)
            $script:logEntries.Add([pscustomobject]@{
                Level = $Level
                Message = $Message
                Data = $Data
            })
        }

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log $log)

        $results[0].Status | Should Be 'Moved'
        $results[0].Handle | Should Be 43
        $script:moveCount | Should Be 1
        $script:startCount | Should Be 0
        $script:waitCount | Should Be 1
        $recoveryLog = @($script:logEntries | Where-Object Message -eq 'Application window handle changed; retrying placement.')
        $recoveryLog.Count | Should Be 1
        $recoveryLog[0].Level | Should Be 'Warning'
        $recoveryLog[0].Data.previousHandle | Should Be 42
        $recoveryLog[0].Data.replacementHandle | Should Be 43
        $recoveryLog[0].Data.attempt | Should Be 2
    }

    It 'stops replacement polling after five placement attempts and continues' {
        $lineWindow = [pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'LINE'
            Title = 'LINE'
            ClassName = 'Chrome_WidgetWin_1'
            Desktop = 'Other'
            Maximized = $false
        }
        $script:notepadWindow = [pscustomobject]@{
            Handle = [long]43
            ProcessId = 101
            ProcessName = 'notepad'
            Title = 'Notepad'
            ClassName = 'Notepad'
            Desktop = 'Other'
            Maximized = $false
        }
        $script:windows = @($lineWindow, $script:notepadWindow)
        $script:waitCount = 0
        $script:adapter.TestWindow = {
            param($Desktop, $Window)
            if ([long]$Window.Handle -eq 42) {
                $script:windows = @($script:notepadWindow)
                throw [System.InvalidOperationException]::new('TYPE_E_ELEMENTNOTFOUND')
            }
            $Window.Desktop -eq $Desktop.Name
        }
        $script:adapter.Wait = {
            param($Milliseconds)
            $script:waitCount++
            $script:now = $script:now.AddMilliseconds($Milliseconds)
        }
        $settings = New-OrchestrationSettings @(
            [pscustomobject]@{
                path = 'LINE'
                windowMatch = [pscustomobject]@{
                    processName = 'LINE'
                    titleRegex = '^LINE$'
                }
            },
            [pscustomobject]@{ path = 'notepad' }
        )

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results.Count | Should Be 2
        $results[0].Status | Should Be 'Failed'
        $results[0].Error | Should Match 'disappeared before placement'
        $results[1].Status | Should Be 'Moved'
        $results[1].Handle | Should Be 43
        $script:waitCount | Should Be 4
    }

    It 'handles an empty window list while polling for a replacement' {
        $lineWindow = [pscustomobject]@{
            Handle = [long]42
            ProcessId = 100
            ProcessName = 'LINE'
            Title = 'LINE'
            ClassName = 'Chrome_WidgetWin_1'
            Desktop = 'Other'
            Maximized = $false
        }
        $script:windows = @($lineWindow)
        $script:waitCount = 0
        $script:adapter.TestWindow = {
            param($Desktop, $Window)
            $script:windows = @()
            throw [System.InvalidOperationException]::new('TYPE_E_ELEMENTNOTFOUND')
        }
        $script:adapter.Wait = {
            param($Milliseconds)
            $script:waitCount++
            $script:now = $script:now.AddMilliseconds($Milliseconds)
        }
        $settings = New-OrchestrationSettings @([pscustomobject]@{
            path = 'LINE'
            windowMatch = [pscustomobject]@{
                processName = 'LINE'
                titleRegex = '^LINE$'
            }
        })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'Failed'
        $results[0].Error | Should Match 'disappeared before placement'
        $script:waitCount | Should Be 4
    }

    It 'rejects a reused handle that no longer matches the selected application' {
        $script:oldWindow = [pscustomobject]@{
            Handle = [long]42; ProcessId = 100; ProcessName = 'LINE'; Title = 'LINE'; ClassName = 'Chrome_WidgetWin_1'; Desktop = 'Other'; Maximized = $false
        }
        $script:reusedHandleWindow = [pscustomobject]@{
            Handle = [long]42; ProcessId = 101; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
        }
        $script:replacementWindow = [pscustomobject]@{
            Handle = [long]43; ProcessId = 100; ProcessName = 'LINE'; Title = 'LINE'; ClassName = 'Chrome_WidgetWin_1'; Desktop = 'Other'; Maximized = $false
        }
        $script:getWindowsCount = 0
        $script:adapter.GetWindows = {
            $script:getWindowsCount++
            if ($script:getWindowsCount -eq 1) {
                @($script:oldWindow)
            } else {
                @($script:reusedHandleWindow, $script:replacementWindow)
            }
        }
        $settings = New-OrchestrationSettings @([pscustomobject]@{
            path = 'LINE'
            windowMatch = [pscustomobject]@{
                processName = 'LINE'
                titleRegex = '^LINE$'
            }
        })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'Moved'
        $results[0].Handle | Should Be 43
        $script:reusedHandleWindow.Desktop | Should Be 'Other'
        $script:replacementWindow.Desktop | Should Be 'Main'
    }

    It 'honors Skip for an existing matching window' {
        $script:windows = @([pscustomobject]@{
            Handle = [long]42; ProcessId = 100; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
        })
        $settings = New-OrchestrationSettings @([pscustomobject]@{ path = 'notepad'; onExisting = 'Skip' })

        $results = @(Invoke-DesktopLayout -Settings $settings -Adapter $script:adapter -Log { param($Level, $Message, $Data) })

        $results[0].Status | Should Be 'Skipped'
        $script:moveCount | Should Be 0
        $script:startCount | Should Be 0
    }
}
