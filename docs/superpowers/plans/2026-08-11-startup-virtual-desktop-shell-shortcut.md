# Startup Virtual Desktop Store Shortcut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Store版Spotifyのシェルショートカットを例外なく起動し、既存のウィンドウ待機・移動・配置検証へ接続する。

**Architecture:** Windowsアダプターがショートカットの対象パス有無を内部メタデータへ変換し、解決済みアプリケーションの `trackStartedProcess` でプロセス追跡の可否を伝える。対象パスが空のシェルショートカットだけ `Start-Process -PassThru` を省略し、Spotifyの `windowMatch` と既存のウィンドウポーリングで実ウィンドウを特定する。

**Tech Stack:** PowerShell 7.5、Pester 3.4、WScript.Shell COM、PSVirtualDesktop 1.5.11、JSON Schema Draft 2020-12

## Global Constraints

- `TargetPath` が空の `.lnk` だけ起動プロセスを直接追跡しない。
- 通常の実行ファイル、コマンド、`TargetPath` が取得できる `.lnk` は従来どおり `Start-Process -PassThru` を使用する。
- `trackStartedProcess` はWindowsアダプター内部の情報とし、公開JSON Schemaへ追加しない。
- ウィンドウ待機、移動、配置検証、最大化、ログ形式、終了コードを変更しない。
- デスクトップ名、順序、アプリケーション順序、Spotifyの `C:\Spotify.lnk` を変更しない。
- `virtual-desktop-setting.json` は個人パスを含むためステージもコミットもしない。
- コードとテストはfeatureブランチでコミットし、レビューと検証後に `develop` へ統合する。

---

### Task 1: ショートカットのプロセス追跡可否を解決する

**Files:**
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1`
- Modify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1`
- Test: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DesktopShortcutMetadata -Path <string>` が返す `targetPath`、`preferredTitle`、`trackStartedProcess`
- Produces: `Resolve-DesktopApplication -App <object>` が返す `trackStartedProcess: bool`

- [ ] **Step 1: 通常ショートカットとシェルショートカットの失敗テストを書く**

既存の通常ショートカットテストへ次の表明を追加する。

~~~powershell
$resolved.trackStartedProcess | Should Be $true
~~~

同じ `Describe 'New-WindowsDesktopAdapter'` へ、空の対象パスを返す内部ヘルパーをモックしたテストを追加する。

~~~powershell
It 'does not track a shell shortcut without a target path' {
    $shortcutPath = Join-Path $TestDrive 'Spotify.lnk'
    $null = New-Item -ItemType File -Path $shortcutPath
    Mock Get-DesktopShortcutMetadata -ModuleName StartupVirtualDesktop.Windows {
        [pscustomobject]@{
            targetPath = ''
            preferredTitle = 'Spotify'
            trackStartedProcess = $false
        }
    } -ParameterFilter { $Path -eq $shortcutPath }
    $adapter = New-WindowsDesktopAdapter
    $resolveApplication = $adapter.ResolveApplication

    $resolved = & $resolveApplication (New-WindowsTestApp -Path $shortcutPath)

    $resolved.inferredProcessName | Should Be 'Spotify'
    $resolved.preferredTitle | Should Be 'Spotify'
    $resolved.trackStartedProcess | Should Be $false
}
~~~

- [ ] **Step 2: Windowsアダプターテストを実行してREDを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1'"
~~~

Expected: `trackStartedProcess` と `Get-DesktopShortcutMetadata` が未実装のため失敗する。

- [ ] **Step 3: 失敗するテストをコミットする**

~~~bash
git add powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1
git commit -m "test: cover shell shortcut process tracking"
~~~

- [ ] **Step 4: ショートカットメタデータの内部ヘルパーを追加する**

`Resolve-DesktopApplication` の直前へ次の内部関数を追加する。モジュールからはexportしない。

~~~powershell
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
~~~

- [ ] **Step 5: 解決済みアプリケーションへ追跡フラグを追加する**

`Resolve-DesktopApplication` の初期値へ次を追加する。

~~~powershell
$trackStartedProcess = $true
~~~

既存の `.lnk` 分岐を内部ヘルパー利用へ置き換える。

~~~powershell
if ([System.IO.Path]::GetExtension($configuredPath).Equals('.lnk', [System.StringComparison]::OrdinalIgnoreCase) -and
    (Test-Path -LiteralPath $configuredPath -PathType Leaf)) {
    $shortcutMetadata = Get-DesktopShortcutMetadata -Path $configuredPath
    $preferredTitle = $shortcutMetadata.preferredTitle
    $trackStartedProcess = $shortcutMetadata.trackStartedProcess
    if (-not [string]::IsNullOrWhiteSpace($shortcutMetadata.targetPath)) {
        $inferredProcessName = [System.IO.Path]::GetFileNameWithoutExtension($shortcutMetadata.targetPath)
    }
} elseif (Test-Path -LiteralPath $configuredPath -PathType Leaf) {
~~~

戻り値の `startedProcessId` の直前へ次を追加する。

~~~powershell
trackStartedProcess = $trackStartedProcess
~~~

- [ ] **Step 6: Windowsアダプターテストを実行してGREENを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1'"
~~~

Expected: `Failed: 0`。通常ショートカットは `true`、空の対象パスは `false` になる。

- [ ] **Step 7: ショートカット分類の実装をコミットする**

~~~bash
git add powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1
git commit -m "feat: classify shell shortcut process tracking"
~~~

### Task 2: シェルショートカットをPassThruなしで起動する

**Files:**
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1`
- Modify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1`
- Test: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1`

**Interfaces:**
- Consumes: `App.trackStartedProcess: bool`。プロパティがない場合は互換性のため `true`
- Produces: `Start-DesktopApplication -App <object>` が返す `ProcessId: int`。非追跡時は `0`

- [ ] **Step 1: 追跡あり・なしの起動テストを書く**

新しい `Describe 'Start-DesktopApplication process tracking'` を追加する。

~~~powershell
Describe 'Start-DesktopApplication process tracking' {
    It 'defaults to PassThru and returns the process id when the tracking flag is omitted' {
        Mock Start-Process -ModuleName StartupVirtualDesktop.Windows {
            [pscustomobject]@{ Id = 4321 }
        }
        $adapter = New-WindowsDesktopAdapter
        $startApplication = $adapter.StartApplication
        $app = [pscustomobject]@{
            launchPath = 'notepad.exe'
            arguments = @()
            workingDirectory = ''
        }

        $result = & $startApplication $app

        $result.ProcessId | Should Be 4321
        Assert-MockCalled Start-Process -ModuleName StartupVirtualDesktop.Windows -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'notepad.exe' -and $PassThru -eq $true -and $ErrorAction -eq 'Stop'
        }
    }

    It 'omits PassThru and returns zero for an untracked shell launch' {
        Mock Start-Process -ModuleName StartupVirtualDesktop.Windows
        $adapter = New-WindowsDesktopAdapter
        $startApplication = $adapter.StartApplication
        $app = [pscustomobject]@{
            launchPath = 'C:\StoreApp.lnk'
            arguments = @()
            workingDirectory = ''
            trackStartedProcess = $false
        }

        $result = & $startApplication $app

        $result.ProcessId | Should Be 0
        Assert-MockCalled Start-Process -ModuleName StartupVirtualDesktop.Windows -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\StoreApp.lnk' -and -not $PassThru -and $ErrorAction -eq 'Stop'
        }
    }
}
~~~

- [ ] **Step 2: Windowsアダプターテストを実行してREDを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1'"
~~~

Expected: 非追跡テストが、現行コードから常に `PassThru = $true` を渡されるため失敗する。

- [ ] **Step 3: 失敗するテストをコミットする**

~~~bash
git add powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1
git commit -m "test: cover untracked shell shortcut launch"
~~~

- [ ] **Step 4: PassThruを条件付きで指定する**

`Start-DesktopApplication` の `$options` 作成から戻り値までを次の内容へ置き換える。

~~~powershell
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
~~~

- [ ] **Step 5: Windowsアダプターテストを実行してGREENを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Windows.Tests.ps1'"
~~~

Expected: `Failed: 0`。フラグ未指定の互換起動はID `4321`、非追跡起動はID `0` を返す。

- [ ] **Step 6: 条件付き起動の実装をコミットする**

~~~bash
git add powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1
git commit -m "fix: launch shell shortcuts without PassThru"
~~~

### Task 3: featureブランチを検証してdevelopへ統合する

**Files:**
- Verify: `powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Windows.psm1`
- Verify: `powershell/startup-virtual-desktop/tests`
- Verify: `powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1`

**Interfaces:**
- Consumes: Task 1のショートカット分類とTask 2の条件付き起動
- Produces: 全自動テストとレビューを通過した `develop`

- [ ] **Step 1: 全Pesterテストを実行する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests'"
~~~

Expected: `Failed: 0`。

- [ ] **Step 2: PowerShell構文とGit差分を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$files = Get-ChildItem "./powershell/startup-virtual-desktop" -Recurse -Include *.ps1,*.psm1; $allErrors = @(); foreach ($file in $files) { $tokens = $null; $errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors); $allErrors += $errors }; if ($allErrors.Count) { $allErrors; exit 1 }; "ParserErrors=0"'
~~~

Expected: `ParserErrors=0`。

Run:

~~~bash
git diff --check develop...HEAD
git status --short
~~~

Expected: 差分エラーなし、作業ツリーに未コミット変更なし。

- [ ] **Step 3: 設計適合性とコード品質のレビューを行う**

レビューでは次を確認する。

- 空の `TargetPath` 以外の起動経路が従来どおり `PassThru` を使う。
- `trackStartedProcess` が公開設定へ漏れていない。
- 非追跡時も起動後のポーリングへ進める戻り値になっている。
- テストが実プロセスや仮想デスクトップを変更せず、分類と起動引数を検証している。

- [ ] **Step 4: featureブランチをdevelopへfast-forward統合する**

元の作業ツリーで実行する。

~~~bash
git merge --ff-only codex/fix-spotify-shell-shortcut
~~~

Expected: コード・テストのコミットだけが `develop` へ追加され、既存の個人設定変更は保持される。

### Task 4: Spotifyの個人設定を更新して統合状態を検証する

**Files:**
- Modify, do not commit: `powershell/startup-virtual-desktop/virtual-desktop-setting.json`
- Reference: `powershell/startup-virtual-desktop/virtual-desktop-setting.schema.json`
- Verify: `powershell/startup-virtual-desktop/logs`

**Interfaces:**
- Consumes: 実ウィンドウのプロセス名 `Spotify` とタイトル `Spotify Premium`
- Produces: 「音楽」デスクトップのSpotifyを明示識別する個人設定

- [ ] **Step 1: SpotifyへwindowMatchを追加する**

「音楽」デスクトップのSpotify設定を次の内容へ置き換える。

~~~json
{
  "path": "C:\\Spotify.lnk",
  "windowMatch": {
    "processName": "Spotify",
    "titleRegex": "Spotify"
  }
}
~~~

- [ ] **Step 2: JSON Schemaとランタイム設定を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$raw = Get-Content "./powershell/startup-virtual-desktop/virtual-desktop-setting.json" -Raw -Encoding utf8; if (-not ($raw | Test-Json -SchemaFile "./powershell/startup-virtual-desktop/virtual-desktop-setting.schema.json" -ErrorAction Stop)) { exit 1 }; Import-Module "./powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1" -Force; $settings = ConvertTo-DesktopLayoutSettings ($raw | ConvertFrom-Json); $null = Test-DesktopLayoutSettings $settings; if (@($settings.warnings).Count -ne 0) { $settings.warnings; exit 1 }; "SettingsValid=True"'
~~~

Expected: `SettingsValid=True`、警告なし。

- [ ] **Step 3: 引数なしの検証実行と全テストを再実行する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -File ./powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1 -ValidateOnly
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests'"
~~~

Expected: 設定検証の終了コード `0`、非推奨警告なし、Pester `Failed: 0`。

- [ ] **Step 4: コミット範囲を最終確認する**

Run:

~~~bash
git diff --check -- powershell/startup-virtual-desktop/virtual-desktop-setting.json
git status --short
~~~

Expected: 未コミット変更は `virtual-desktop-setting.json` だけ。個人設定はステージもコミットもしない。

- [ ] **Step 5: Windows実環境での受け入れ条件を確認する**

ユーザーが通常どおりスクリプトを実行した後、最新JSONLログのSpotify結果が `Moved` または `AlreadyPlaced`、`DesktopName` が `音楽`、`Handle` が `0` より大きいことを確認する。自動テストでは実アプリや仮想デスクトップを変更しないため、この実行だけは手動受け入れ確認とする。
