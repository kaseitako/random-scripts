# Startup Virtual Desktop Window Handle Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 起動中にトップレベルウィンドウのハンドルが差し替わっても、最新ウィンドウを再取得して仮想デスクトップへの配置を完了する。

**Architecture:** コアの配置直前に現在のトップレベルウィンドウを再列挙し、選択済みハンドルが消えていれば既存の `Get-BestApplicationWindow` で代替ウィンドウを選び直す。配置APIを最大5回・200ms間隔で再試行し、通常ケースには待機を追加せず、最終的に検証できたハンドルを結果へ記録する。

**Tech Stack:** PowerShell 7.6、Pester 3.4、PSVirtualDesktop 1.5.11、アダプター方式のインメモリテスト

## Global Constraints

- LINE固有の条件分岐や固定スリープを追加しない。
- 再取得は既存の `windowMatch`、推測条件、ハンドル重複防止を利用する。
- 配置試行は最大5回、試行間隔は200ms、追加待機の上限は800msとする。
- 通常ケースではアダプターの `Wait` を呼び出さない。
- アプリケーションを再起動せず、起動順序と起動回数を変更しない。
- `onExisting = Skip` の動作を変更しない。
- JSON Schema、個人設定、Windowsアダプターの公開インターフェースを変更しない。
- `virtual-desktop-setting.json` の既存ローカル変更は保持し、ステージもコミットもしない。
- コードとテストはfeatureブランチでコミットし、レビューと検証後に `develop` へ統合する。

---

### Task 1: 差し替わったウィンドウを再取得して配置する

**Files:**
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`
- Modify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1`
- Test: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`

**Interfaces:**
- Consumes: `Update-ApplicationWindowSelection -App <object> -SelectedWindow <object> -Windows <object[]> -AssignedHandles <hashtable>`
- Produces: 現在も有効な同一ハンドル、または同じアプリ条件に一致する代替ウィンドウ。代替取得時は古い予約を削除して新しいハンドルを予約する
- Produces: `Invoke-DesktopLayout` が最大5回の配置試行を行い、成功時は最終ハンドルを持つ `Moved` または `AlreadyPlaced` を返す

- [ ] **Step 1: ハンドル差し替えから回復する失敗テストを書く**

`Describe 'Invoke-DesktopLayout'` へ次のテストを追加する。

~~~powershell
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
    $replacementWindow = [pscustomobject]@{
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
            $script:windows = @($replacementWindow)
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
~~~

- [ ] **Step 2: 代替ウィンドウが現れない場合の失敗テストを書く**

同じ `Describe` へ、試行上限と後続処理を検証するテストを追加する。

~~~powershell
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
    $notepadWindow = [pscustomobject]@{
        Handle = [long]43
        ProcessId = 101
        ProcessName = 'notepad'
        Title = 'Notepad'
        ClassName = 'Notepad'
        Desktop = 'Other'
        Maximized = $false
    }
    $script:windows = @($lineWindow, $notepadWindow)
    $script:waitCount = 0
    $script:adapter.TestWindow = {
        param($Desktop, $Window)
        if ([long]$Window.Handle -eq 42) {
            $script:windows = @($notepadWindow)
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
~~~

- [ ] **Step 3: 再利用された同一数値ハンドルを誤選択しない失敗テストを書く**

同じ `Describe` へ、別アプリケーションに再利用されたハンドルを拒否するテストを追加する。

~~~powershell
It 'rejects a reused handle that no longer matches the selected application' {
    $oldWindow = [pscustomobject]@{
        Handle = [long]42; ProcessId = 100; ProcessName = 'LINE'; Title = 'LINE'; ClassName = 'Chrome_WidgetWin_1'; Desktop = 'Other'; Maximized = $false
    }
    $reusedHandleWindow = [pscustomobject]@{
        Handle = [long]42; ProcessId = 101; ProcessName = 'notepad'; Title = 'Notepad'; ClassName = 'Notepad'; Desktop = 'Other'; Maximized = $false
    }
    $replacementWindow = [pscustomobject]@{
        Handle = [long]43; ProcessId = 100; ProcessName = 'LINE'; Title = 'LINE'; ClassName = 'Chrome_WidgetWin_1'; Desktop = 'Other'; Maximized = $false
    }
    $script:getWindowsCount = 0
    $script:adapter.GetWindows = {
        $script:getWindowsCount++
        if ($script:getWindowsCount -eq 1) {
            @($oldWindow)
        } else {
            @($reusedHandleWindow, $replacementWindow)
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
    $reusedHandleWindow.Desktop | Should Be 'Other'
    $replacementWindow.Desktop | Should Be 'Main'
}
~~~

- [ ] **Step 4: コアテストを実行してREDを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1'"
~~~

Expected: 差し替えテストは最初の `TYPE_E_ELEMENTNOTFOUND` で `Failed` になり、上限テストは待機回数が `0` で失敗し、ハンドル再利用テストは古いハンドル `42` を結果にするため失敗する。

- [ ] **Step 5: 失敗する回帰テストをコミットする**

~~~bash
git add powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1
git commit -m "test: cover replaced application windows"
~~~

- [ ] **Step 6: 最新ウィンドウを選び直す内部ヘルパーを追加する**

`Get-BestApplicationWindow` の直後へ次の関数を追加し、export対象には含めない。

~~~powershell
function Update-ApplicationWindowSelection {
    param(
        [Parameter(Mandatory)]
        [object]$App,

        [Parameter(Mandatory)]
        [object]$SelectedWindow,

        [Parameter(Mandatory)]
        [object[]]$Windows,

        [Parameter(Mandatory)]
        [hashtable]$AssignedHandles
    )

    $selectedHandle = [long]$SelectedWindow.Handle
    foreach ($window in @($Windows)) {
        if ([long]$window.Handle -eq $selectedHandle -and
            [int]$window.ProcessId -eq [int]$SelectedWindow.ProcessId) {
            return $window
        }
    }

    $null = $AssignedHandles.Remove([string]$selectedHandle)
    $replacement = Get-BestApplicationWindow -App $App -Windows @($Windows) -ExcludedHandles $AssignedHandles
    if ($null -ne $replacement) {
        $AssignedHandles[[string][long]$replacement.Handle] = $true
    }

    return $replacement
}
~~~

- [ ] **Step 7: 配置処理を最大5回の再取得ループへ置き換える**

`Invoke-DesktopLayout` のアダプター操作取得部へ次を追加する。

~~~powershell
$wait = $Adapter.Wait
$placementAttemptLimit = 5
~~~

既存の `$status = 'AlreadyPlaced'` から移動検証までを次の内容へ置き換える。

~~~powershell
$status = 'AlreadyPlaced'
$placementSucceeded = $false
$placementError = $null
for ($placementAttempt = 1; $placementAttempt -le $placementAttemptLimit; $placementAttempt++) {
    $previousWindow = $window
    $currentWindow = Update-ApplicationWindowSelection -App $app -SelectedWindow $window -Windows @(& $getWindows) -AssignedHandles $assignedHandles

    if ($null -eq $currentWindow) {
        $placementError = [System.InvalidOperationException]::new('Application window disappeared before placement.')
    } else {
        $window = $currentWindow
        if ([long]$previousWindow.Handle -ne [long]$window.Handle) {
            Write-DesktopLayoutLog -Log $Log -Level 'Warning' -Message 'Application window handle changed; retrying placement.' -Data @{
                desktopName = $desktop.name
                path = $app.path
                previousHandle = [long]$previousWindow.Handle
                replacementHandle = [long]$window.Handle
                attempt = $placementAttempt
            }
        }

        try {
            $status = 'AlreadyPlaced'
            if (-not (& $testWindow $targetDesktop $window)) {
                $null = & $moveWindow $targetDesktop $window
                if (-not (& $testWindow $targetDesktop $window)) {
                    throw 'Window movement verification failed.'
                }
                $status = 'Moved'
            }
            $placementSucceeded = $true
            break
        } catch {
            $placementError = $_.Exception
        }
    }

    if ($placementAttempt -lt $placementAttemptLimit) {
        & $wait 200
    }
}

if (-not $placementSucceeded) {
    throw $placementError
}
~~~

- [ ] **Step 8: コアテストを実行してGREENを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1'"
~~~

Expected: `Failed: 0`。差し替え結果はハンドル `43` の `Moved`、代替なしは4回待機後に `Failed`、後続notepadは `Moved` となる。

- [ ] **Step 9: 実装をコミットする**

~~~bash
git add powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1
git commit -m "fix: reacquire replaced application windows"
~~~

### Task 2: featureブランチを検証・レビューしてdevelopへ統合する

**Files:**
- Verify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1`
- Verify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Core.Tests.ps1`
- Verify: `powershell/startup-virtual-desktop/tests`
- Preserve, do not commit: `powershell/startup-virtual-desktop/virtual-desktop-setting.json`

**Interfaces:**
- Consumes: Task 1の最大5回のハンドル再取得・配置処理
- Produces: 全テストと独立レビューを通過した `develop`

- [ ] **Step 1: 全Pesterテストを実行する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests'"
~~~

Expected: `Failed: 0`。

- [ ] **Step 2: PowerShell構文と設定を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$files = Get-ChildItem "./powershell/startup-virtual-desktop" -Recurse -Include *.ps1,*.psm1; $allErrors = @(); foreach ($file in $files) { $tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors); $allErrors += $errors }; if ($allErrors.Count) { $allErrors; exit 1 }; "ParserErrors=0"'
~~~

Expected: `ParserErrors=0`。

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -File ./powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1 -ValidateOnly
~~~

Expected: 終了コード `0`、設定検証成功、非推奨警告なし。

- [ ] **Step 3: Git差分と作業ツリーを検証する**

Run:

~~~bash
git diff --check develop...HEAD
git status --short
git log --oneline develop..HEAD
~~~

Expected: feature worktreeは未コミット変更なし。差分はコアモジュールとコアテストだけで、テストコミットと実装コミットが存在する。

- [ ] **Step 4: 独立コードレビューを行う**

レビューでは次を確認する。

- 通常ケースで固定待機が発生しない。
- 古い予約が削除され、新しいハンドルだけが予約される。
- 他アプリへ予約済みのハンドルを代替として選ばない。
- `Skip`、最大化、起動回数、後続継続、結果ステータスが維持される。
- 再試行が5回で終了し、最後に検証したハンドルが結果へ記録される。

- [ ] **Step 5: featureブランチをdevelopへfast-forward統合する**

元の作業ツリーで実行する。

~~~bash
git merge --ff-only codex/fix-window-handle-recovery
~~~

Expected: featureコミットだけが `develop` へ追加され、個人設定の未コミット変更は保持される。

- [ ] **Step 6: developで最終検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests'"
pwsh.exe -NoLogo -NoProfile -File ./powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1 -ValidateOnly
~~~

Expected: Pester `Failed: 0`、設定検証の終了コード `0`。

Run:

~~~bash
git diff --check
git status --short
~~~

Expected: 未コミット変更は個人設定 `virtual-desktop-setting.json` だけ。

- [ ] **Step 7: Windows再起動時の手動受け入れ条件を確認する**

次回スタートアップ実行後、最新JSONLログでLINEの結果が `Moved` または `AlreadyPlaced`、`DesktopName` が `メイン`、`Handle` が `0` より大きいことを確認する。ハンドルが差し替わった場合は `Application window handle changed; retrying placement.` の警告と、最終結果に新しいハンドルが記録されることを確認する。
