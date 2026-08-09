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
