Import-Module -Name ".\modules\Request-NamedDesktop.psm1"

# 壁紙設定用のC#のコードを定義
$setwallpapersource = @"
using System.Runtime.InteropServices;
public class wallpaper
{
	public const int SetDesktopWallpaper = 20;
	public const int UpdateIniFile = 0x01;
	public const int SendWinIniChange = 0x02;
	[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
	private static extern int SystemParametersInfo (int uAction, int uParam, string lpvParam, int fuWinIni);
	public static void SetWallpaper ( string path ) {
		SystemParametersInfo( SetDesktopWallpaper, 0, path, UpdateIniFile | SendWinIniChange );
	}
}
"@
Add-Type -TypeDefinition $setwallpapersource

$json = Get-Content -Path "virtual-desktop-setting.json" -Raw | ConvertFrom-Json

Write-Output "仮想デスクトップとアプリケーションを起動します..."
$currentDesktop = Get-CurrentDesktop


foreach ($desktop in $json.desktops) {
	$targetDesktop = Request-NamedDesktop -name $desktop.name
	Switch-Desktop $targetDesktop

	foreach ($app in $desktop.apps) {

		$options = @{
			FilePath = $app.path
			# PassThru = $true
		}

		if ($app.fullscreen -eq $true) {
			$options["WindowStyle"] = "Maximized" # フルスクリーンで起動
		}

		# アプリケーションを起動
		try {
			Start-Process @options

			# うまくいかなかったのでコメントアウト
			# $process = Start-Process @options
			# $hwnd = $process.MainWindowHandle
			# if ($app.pinned -eq $true) {
			# 	Pin-Application $hwnd # ピン留め
			# }
		} catch {
			Write-Error "Failed to start process for $($app.path): $_"
			continue
		}
	}

	# 壁紙のパスが存在する場合は、その壁紙に変更する
	if (Test-Path -Path $desktop.wallpaperAbsolutePath) {
		[wallpaper]::SetWallpaper($desktop.wallpaperAbsolutePath)
	}

	Start-Sleep 3
}

Switch-Desktop $currentDesktop
Write-Output "仮想デスクトップとアプリケーションの起動が完了しました。"
