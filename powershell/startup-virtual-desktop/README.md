# [README] Startup-VirtualDesktop.ps1

## これはなに？

- jsonに設定した内容で、仮想デスクトップやアプリケーションを起動するPowerShellスクリプト
- Windowsでのみ動作する
- [PSVirtualDesktop](https://github.com/MScholtes/PSVirtualDesktop) を利用している

## 環境など

- PowerShell 7.5.0 で動作確認

```plaintext
PS C:\> $PSVersionTable

Name                           Value
----                           -----
PSVersion                      7.5.0
```

- [PSVirtualDesktop](https://github.com/MScholtes/PSVirtualDesktop) をREADMEを読んでインストールする

```plaintext
PS C:\> Install-Module VirtualDesktop
```

## 知っていると良いこと

- タスクバーのアプリケーションのショートカットは以下に設定されている

```plaintext
%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar
```

- Windows Storeでインストールしたアプリはexeが難しい場所にあるので、以下のフォルダからショートカットを作成してショートカットを起動するとよい

```plaintext
shell:AppsFolder
```

- スタートアップで実行させたい場合は、以下にショートカットを配置すれば良い

```plaintext
shell:startup
```

## その他

### 何故作ろうと思った？

- Macと違い、Windowsは電源を落とすとアプリケーションを立ち上げ直す必要があるので自動で起動させたかった
