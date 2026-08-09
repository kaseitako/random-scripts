# Startup Virtual Desktop Personal Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 引数なし起動を修復し、個人設定を非推奨項目のない一意なウィンドウ照合条件へ更新する。

**Architecture:** 起動スクリプトでは空文字を既定パスの選択値として明示的に許可し、既存のパス解決ロジックを維持する。個人設定では実プロセス名とウィンドウタイトルを `windowMatch` に固定し、個人パスを含むファイルはローカル変更のままコミットしない。

**Tech Stack:** PowerShell 7.5、Pester 3.4、JSON Schema Draft 2020-12

## Global Constraints

- 仮想デスクトップの名前、順序、アプリケーションの順序、起動パスを変更しない。
- 既定の `timeoutSeconds=30` と `onExisting=Move` を変更しない。
- ログ形式、終了コード、配置アルゴリズムを変更しない。
- `virtual-desktop-setting.json` は個人パスを含むためコミットしない。
- コードとテストはfeatureブランチでコミットし、検証後に `develop` へ統合する。
- Task 1のfeatureブランチをレビュー・統合・片付けしてから、元の `develop` 作業ツリーでTask 2の個人設定を更新する。

---

### Task 1: 引数なし起動の回帰テストと修正

**Files:**
- Modify: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Entry.Tests.ps1`
- Modify: `powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1`
- Test: `powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Entry.Tests.ps1`

**Interfaces:**
- Consumes: `Resolve-StartupPath -Path '' -DefaultPath <absolute-path>`
- Produces: `SettingsPath` を省略しても既定の `virtual-desktop-setting.json` を読み込めるエントリポイント

- [ ] **Step 1: テストヘルパーを省略可能なSettingsPathへ対応させ、失敗するテストを書く**

引数配列から固定の `-SettingsPath` を外し、値が指定された場合だけ追加する。

~~~powershell
function Invoke-EntryScriptProcess {
    param(
        [AllowEmptyString()]
        [string]$SettingsPath = '',

        [Parameter(Mandatory)]
        [string]$LogDirectory
    )

    $id = [guid]::NewGuid().ToString('N')
    $standardOutput = Join-Path $TestDrive "$id.stdout.txt"
    $standardError = Join-Path $TestDrive "$id.stderr.txt"
    $arguments = @(
        '-NoLogo', '-NoProfile', '-File', $script:scriptPath,
        '-LogDirectory', $LogDirectory,
        '-ValidateOnly'
    )
    if (-not [string]::IsNullOrWhiteSpace($SettingsPath)) {
        $arguments += @('-SettingsPath', $SettingsPath)
    }
    $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $standardOutput -RedirectStandardError $standardError
    $redirectEncoding = [Console]::OutputEncoding
    $standardOutputText = $redirectEncoding.GetString([IO.File]::ReadAllBytes($standardOutput))
    $standardErrorText = $redirectEncoding.GetString([IO.File]::ReadAllBytes($standardError))

    [pscustomobject]@{
        ExitCode = $process.ExitCode
        Output = $standardOutputText + $standardErrorText
    }
}
~~~

別のカレントディレクトリから既定設定を検証するテストを追加する。

~~~powershell
It 'uses the default settings path when SettingsPath is omitted' {
    $logDirectory = Join-Path $TestDrive 'default-settings-logs'

    Push-Location $TestDrive
    try {
        $result = Invoke-EntryScriptProcess -LogDirectory $logDirectory
    } finally {
        Pop-Location
    }

    $result.ExitCode | Should Be 0
    $result.Output | Should Match '設定の検証に成功しました'
}
~~~

- [ ] **Step 2: エントリポイントテストを実行してREDを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Entry.Tests.ps1'"
~~~

Expected: 追加テストが `Cannot bind argument to parameter 'Path' because it is an empty string.` を含む理由で失敗する。

- [ ] **Step 3: 失敗するテストをコミットする**

~~~bash
git add powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Entry.Tests.ps1
git commit -m "test: cover default startup settings path"
~~~

- [ ] **Step 4: Pathパラメーターだけに空文字許可を追加する**

~~~powershell
function Resolve-StartupPath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$DefaultPath
    )
~~~

- [ ] **Step 5: エントリポイントテストを実行してGREENを確認する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests/StartupVirtualDesktop.Entry.Tests.ps1'"
~~~

Expected: `Failed: 0`。

- [ ] **Step 6: コード修正をコミットする**

~~~bash
git add powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1
git commit -m "fix: allow default startup paths"
~~~

### Task 2: 個人設定を現行形式へ移行する

**Files:**
- Modify, do not commit: `powershell/startup-virtual-desktop/virtual-desktop-setting.json`
- Reference: `powershell/startup-virtual-desktop/virtual-desktop-setting.schema.json`

**Interfaces:**
- Consumes: 実ウィンドウから確認したプロセス名とタイトル
- Produces: 非推奨項目がなく、曖昧な6アプリを明示識別する個人設定

- [ ] **Step 1: 個人設定を次の完全な内容へ更新する**

~~~json
{
  "$schema": "./virtual-desktop-setting.schema.json",
  "desktops": [
    {
      "name": "メイン",
      "apps": [
        {
          "path": "chrome",
          "windowMatch": {
            "processName": "chrome",
            "titleRegex": "Google Chrome$"
          }
        },
        {
          "path": "C:\\Users\\kanto\\AppData\\Local\\LINE\\bin\\LineLauncher.exe",
          "windowMatch": {
            "processName": "LINE",
            "titleRegex": "^LINE$"
          }
        },
        {
          "path": "C:\\Users\\kanto\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Discord Inc\\Discord.lnk",
          "windowMatch": {
            "processName": "Discord",
            "titleRegex": "Discord"
          }
        }
      ],
      "wallpaperAbsolutePath": ""
    },
    {
      "name": "音楽",
      "apps": [
        {
          "path": "C:\\Spotify.lnk"
        },
        {
          "path": "C:\\Users\\kanto\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Chrome アプリ\\SoundCloud.lnk",
          "windowMatch": {
            "processName": "chrome",
            "titleRegex": "SoundCloud"
          }
        }
      ]
    },
    {
      "name": "Misskey.io",
      "apps": [
        {
          "path": "C:\\Users\\kanto\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Chrome アプリ\\Misskey.io.lnk",
          "maximized": true,
          "windowMatch": {
            "processName": "chrome",
            "titleRegex": "Misskey\\.io"
          }
        }
      ]
    },
    {
      "name": "みすてむず",
      "apps": [
        {
          "path": "C:\\Users\\kanto\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Chrome アプリ\\みすてむず　いず　みすきーしすてむず.lnk",
          "maximized": true,
          "windowMatch": {
            "processName": "chrome",
            "titleRegex": "みすてむず"
          }
        }
      ]
    },
    {
      "name": "カレンダー",
      "apps": [
        {
          "path": "C:\\Users\\kanto\\AppData\\Local\\Programs\\cron-web\\Notion Calendar.exe",
          "maximized": true
        }
      ]
    }
  ]
}
~~~

- [ ] **Step 2: JSON Schemaとランタイム設定を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$raw = Get-Content "./powershell/startup-virtual-desktop/virtual-desktop-setting.json" -Raw -Encoding utf8; if (-not ($raw | Test-Json -SchemaFile "./powershell/startup-virtual-desktop/virtual-desktop-setting.schema.json" -ErrorAction Stop)) { exit 1 }; Import-Module "./powershell/startup-virtual-desktop/modules/StartupVirtualDesktop.Core.psm1" -Force; $settings = ConvertTo-DesktopLayoutSettings ($raw | ConvertFrom-Json); $null = Test-DesktopLayoutSettings $settings; if (@($settings.warnings).Count -ne 0) { $settings.warnings; exit 1 }; "SettingsValid=True"'
~~~

Expected: `SettingsValid=True`、警告なし。

- [ ] **Step 3: 全絶対パスの存在を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$settings = Get-Content "./powershell/startup-virtual-desktop/virtual-desktop-setting.json" -Raw -Encoding utf8 | ConvertFrom-Json; $missing = @(foreach ($desktop in $settings.desktops) { foreach ($app in $desktop.apps) { if ([IO.Path]::IsPathRooted($app.path) -and -not (Test-Path -LiteralPath $app.path -PathType Leaf)) { $app.path } } }); if ($missing.Count) { $missing; exit 1 }; "MissingPaths=0"'
~~~

Expected: `MissingPaths=0`。

- [ ] **Step 4: 非推奨項目が残っていないことを確認する**

Run:

~~~bash
rg -n '"(waitSeconds|fullscreen)"' powershell/startup-virtual-desktop/virtual-desktop-setting.json
~~~

Expected: 一致なし。

個人設定はステージもコミットもしない。

### Task 3: 統合後の最終検証

**Files:**
- Verify: `powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1`
- Verify: `powershell/startup-virtual-desktop/virtual-desktop-setting.json`
- Verify: `powershell/startup-virtual-desktop/tests`

**Interfaces:**
- Consumes: Task 1の既定パス修正とTask 2の個人設定
- Produces: 引数なしの `-ValidateOnly` が成功する統合済み `develop`

- [ ] **Step 1: 全Pesterテストと構文検証を実行する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command "Invoke-Pester -Path './powershell/startup-virtual-desktop/tests'"
~~~

Expected: `Failed: 0`。

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -Command '$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path "./powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1"), [ref]$tokens, [ref]$errors); if ($errors.Count) { $errors; exit 1 }; "ParserErrors=0"'
~~~

Expected: `ParserErrors=0`。

- [ ] **Step 2: 引数なしで個人設定を検証する**

Run:

~~~powershell
pwsh.exe -NoLogo -NoProfile -File ./powershell/startup-virtual-desktop/Startup-VirtualDesktop.ps1 -ValidateOnly
~~~

Expected: 終了コード0、日本語の「設定の検証に成功しました」、非推奨警告なし。

- [ ] **Step 3: 差分とコミット範囲を確認する**

~~~bash
git diff --check -- powershell/startup-virtual-desktop/virtual-desktop-setting.json
git status --short
~~~

Expected: 未コミット変更は個人設定だけで、コードとテストはコミット済み。
