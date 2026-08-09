# Startup Virtual Desktop 個人設定更新設計

## 目的

個人設定を現行仕様へ移行し、PC起動時に既存ウィンドウを誤認しにくい条件へ更新する。あわせて、引数を指定しない通常起動が設定読込前に失敗する不具合を修正する。

## 現状確認

- 個人設定は現行の正規化・検証処理を通過する。
- 設定された絶対パスとショートカット7件はすべて存在する。
- `waitSeconds` は非推奨で、現在は無視される。
- `fullscreen` は `maximized` の非推奨エイリアスである。
- LINEは設定パスから `LineLauncher` と推測されるが、実ウィンドウのプロセス名は `LINE` である。
- Discordショートカットは `Update` と推測されるが、実ウィンドウのプロセス名は `Discord` である。
- Chromeアプリは `chrome_proxy` と推測されるが、実ウィンドウのプロセス名は `chrome` である。
- 引数を省略すると、空文字の `SettingsPath` が必須文字列パラメーターで拒否される。

## 個人設定の変更

デスクトップの順序、名前、アプリの順序、起動パスは維持する。

- ルートへ `"$schema": "./virtual-desktop-setting.schema.json"` を追加する。
- `waitSeconds` を削除する。
- `fullscreen: true` 3件を `maximized: true` へ置換する。
- 次の `windowMatch` を追加する。

| アプリ | processName | titleRegex |
|---|---|---|
| 通常Chrome | `chrome` | `Google Chrome$` |
| LINE | `LINE` | `^LINE$` |
| Discord | `Discord` | `Discord` |
| SoundCloud | `chrome` | `SoundCloud` |
| Misskey.io | `chrome` | `Misskey\.io` |
| みすてむず | `chrome` | `みすてむず` |

これらの条件は、設計時点で開いている実ウィンドウに対してそれぞれ1件だけ一致することを確認済みである。SpotifyとNotion Calendarは実行ファイル名の自動推測が実プロセス名と一致するため、明示条件を追加しない。

個人パスを含む `virtual-desktop-setting.json` はコミット対象に含めず、ローカル変更として保持する。

## 起動スクリプトの修正

`Resolve-StartupPath` の `Path` パラメーターへ `[AllowEmptyString()]` を追加する。空文字は既存ロジックによって `DefaultPath` へ置き換えられるため、制御フローやパス解決規則は変更しない。

`DefaultPath` は空文字を許可せず、既存の必須指定を維持する。

## テスト

- エントリポイントテストから `SettingsPath` を省略できるようテストヘルパーを調整する。
- 別のカレントディレクトリから `SettingsPath` を省略して `-ValidateOnly` を実行し、既定設定ファイルが読み込まれることを確認する。
- 個人設定を `-ValidateOnly` で検証し、非推奨警告がなくなることを確認する。
- 個人設定の全絶対パスが引き続き存在することを確認する。
- 全Pesterテスト、PowerShell構文検証、JSON解析を実行する。

## 変更しないもの

- 仮想デスクトップの名前と順序
- アプリケーションの起動順序とパス
- 既定のタイムアウトと `onExisting` の挙動
- ログ形式、終了コード、配置アルゴリズム
