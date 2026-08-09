# Startup-VirtualDesktop.ps1

JSONの定義に合わせて、Windowsの仮想デスクトップとアプリケーションのウィンドウ配置を復元するPowerShellスクリプトです。

固定秒数を待ってデスクトップを切り替える方式ではありません。ウィンドウが現れるまで上限付きで待機し、PSVirtualDesktopの `Move-Window` で対象デスクトップへ移動した後、`Test-Window` で配置を確認します。

## 動作環境

- Windows 10またはWindows 11
- PowerShell 7.5以降
- [PSVirtualDesktop](https://github.com/MScholtes/PSVirtualDesktop) 1.5.9以降
  - 1.5.11以降を推奨

```powershell
Install-Module VirtualDesktop -Scope CurrentUser
Update-Module VirtualDesktop
Get-Module -ListAvailable VirtualDesktop |
    Sort-Object Version -Descending |
    Select-Object -First 1 Name, Version
```

Windowsの大型アップデート後は、PSVirtualDesktopの対応状況も確認してください。

## セットアップ

1. サンプルをコピーして個人設定を作成します。

```powershell
Copy-Item .\virtual-desktop-setting.sample.json .\virtual-desktop-setting.json
```

2. `virtual-desktop-setting.json` を編集します。
3. アプリを起動せずに、設定と実行環境を検証します。

```powershell
pwsh.exe -NoProfile -File .\Startup-VirtualDesktop.ps1 -ValidateOnly
```

4. 手動実行で確認します。

```powershell
pwsh.exe -NoProfile -File .\Startup-VirtualDesktop.ps1
```

スクリプト、モジュール、設定のパスは `$PSScriptRoot` から解決されます。ショートカットの「作業フォルダー」には依存しません。

## 設定

[virtual-desktop-setting.sample.json](./virtual-desktop-setting.sample.json) と [JSON Schema](./virtual-desktop-setting.schema.json) を参照してください。

### デスクトップ

| プロパティ | 必須 | 説明 |
|---|---|---|
| `name` | はい | 一意な仮想デスクトップ名 |
| `apps` | いいえ | 配置するアプリケーションの配列 |
| `wallpaperAbsolutePath` | いいえ | Windows 11のデスクトップ別壁紙 |
| `waitSeconds` | いいえ | 後方互換のため読み取るが無視される非推奨設定 |

定義にない既存デスクトップは削除しません。

### アプリケーション

| プロパティ | 既定値 | 説明 |
|---|---:|---|
| `path` | 必須 | exe、PATH上のコマンド、または `.lnk` |
| `arguments` | `[]` | コマンドライン引数の文字列配列 |
| `workingDirectory` | 空 | 起動時の作業ディレクトリ |
| `timeoutSeconds` | `30` | ウィンドウ出現を待つ上限。1～300秒 |
| `onExisting` | `Move` | 既存ウィンドウの扱い |
| `maximized` | `false` | 配置確認後に最大化 |
| `fullscreen` | `false` | `maximized` の後方互換エイリアス |
| `windowMatch` | 自動推測 | 対象ウィンドウを明示的に識別する条件 |

`onExisting` は次のいずれかです。

- `Move`: 既存ウィンドウを再利用して対象デスクトップへ移動する
- `Skip`: 既存ウィンドウがあれば変更しない
- `Launch`: 既存ウィンドウがあっても新しいウィンドウを起動する

### ウィンドウの識別

`windowMatch` を省略すると、実行ファイル名、ショートカットのリンク先、ショートカット名、新規作成されたウィンドウから自動推測します。

Chromeアプリ、PWA、Electronアプリなど、同じプロセス名を複数の設定で使う場合は `windowMatch` を明示してください。指定した条件はすべてANDで評価されます。

```json
{
  "path": "C:\\Users\\me\\AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Chrome アプリ\\SoundCloud.lnk",
  "timeoutSeconds": 45,
  "onExisting": "Move",
  "maximized": true,
  "windowMatch": {
    "processName": "chrome",
    "titleRegex": "SoundCloud",
    "classNameRegex": "Chrome_WidgetWin"
  }
}
```

使用できる条件は次のとおりです。

- `processName`: 拡張子を除いたプロセス名。大文字・小文字は区別しない
- `titleRegex`: ウィンドウタイトルのPowerShell正規表現
- `classNameRegex`: Win32ウィンドウクラス名のPowerShell正規表現

## Windowsスタートアップ

`shell:startup` をエクスプローラーのアドレスバーへ入力し、次のようなターゲットのショートカットを配置します。

```text
"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo -NoProfile -WindowStyle Hidden -File "C:\path\to\startup-virtual-desktop\Startup-VirtualDesktop.ps1"
```

スクリプトはExplorerが利用可能になるまで200ミリ秒間隔、最大30秒だけ状態を確認します。二重起動はユーザー単位のMutexで検知し、後から起動した側が何も変更せず終了します。

タスクスケジューラを使う場合は「ユーザーのログオン時」に実行し、「ユーザーがログオンしているときのみ実行する」を選択してください。非対話セッションではアプリケーションウィンドウを操作できません。

## ログ

既定では `logs/startup-virtual-desktop-日時-PID.jsonl` にJSON Lines形式で記録します。

```powershell
pwsh.exe -NoProfile -File .\Startup-VirtualDesktop.ps1 `
    -LogDirectory C:\Logs\StartupVirtualDesktop
```

記録内容には次が含まれます。

- Windowsビルド、PowerShell、VirtualDesktopモジュールのバージョン
- デスクトップ名、アプリケーションパス
- 選択したウィンドウハンドルとプロセス名
- `Moved`、`AlreadyPlaced`、`Skipped`、`Failed` の結果
- タイムアウト、起動、移動、配置確認のエラー

1アプリが `Failed` になっても、残りのアプリは処理されます。1件以上失敗した場合の終了コードは1、設定・依存関係のエラーは2です。

## トラブルシューティング

### 別のウィンドウが選ばれる

同じプロセス名のアプリが複数ある場合は、`titleRegex` または `classNameRegex` を追加します。Chrome/PWAではプロセス名だけでなくタイトルも指定してください。

### ウィンドウを移動できない

管理者として起動されたアプリのウィンドウは、通常権限のスクリプトから操作できないことがあります。対象アプリとスクリプトの権限レベルをそろえてください。必要な場合だけ、タスクスケジューラからスクリプトも管理者権限で実行します。

### 起動がタイムアウトする

対象アプリの `timeoutSeconds` を増やし、ログのプロセス名とタイトルを確認して `windowMatch` を調整します。固定スリープを追加する必要はありません。

### Windows更新後に動かない

`Update-Module VirtualDesktop` を実行し、ログのWindowsビルドとモジュールバージョンを確認してください。

## コールドスタート確認

1. `-ValidateOnly` が終了コード0になることを確認する。
2. Windowsからサインアウトまたは再起動する。
3. 各設定アプリのウィンドウが対象デスクトップにあることを確認する。
4. ログに `Failed` がないことを確認する。
5. 誤認識があれば、そのアプリにだけ `windowMatch` を追加する。
