$projectPath = Split-Path $PSScriptRoot -Parent
$coreModulePath = Join-Path $projectPath 'modules\StartupVirtualDesktop.Core.psm1'
$samplePath = Join-Path $projectPath 'virtual-desktop-setting.sample.json'
$schemaPath = Join-Path $projectPath 'virtual-desktop-setting.schema.json'
$readmePath = Join-Path $projectPath 'README.md'
Import-Module $coreModulePath -Force

Describe 'configuration artifacts' {
    It 'normalizes and validates the sample without deprecation warnings' {
        $raw = Get-Content -LiteralPath $samplePath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100

        $settings = ConvertTo-DesktopLayoutSettings -InputObject $raw

        $null = Test-DesktopLayoutSettings -Settings $settings
        $settings.warnings.Count | Should Be 0
        $settings.desktops.Count | Should BeGreaterThan 1
    }

    It 'provides a parseable JSON schema with application matching fields' {
        $schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 100
        $appProperties = $schema.'$defs'.application.properties

        $schema.'$schema' | Should Match 'json-schema.org'
        ($appProperties.PSObject.Properties.Name -contains 'windowMatch') | Should Be $true
        ($appProperties.PSObject.Properties.Name -contains 'onExisting') | Should Be $true
        ($appProperties.PSObject.Properties.Name -contains 'timeoutSeconds') | Should Be $true
    }

    It 'documents startup validation matching logs and limitations' {
        $readme = Get-Content -LiteralPath $readmePath -Raw -Encoding utf8

        $readme | Should Match '-ValidateOnly'
        $readme | Should Match 'windowMatch'
        $readme | Should Match 'onExisting'
        $readme | Should Match 'Update-Module'
        $readme | Should Match 'pwsh.exe'
        $readme | Should Match 'logs'
        $readme | Should Match 'Chrome'
        $readme | Should Match '管理者'
    }
}
