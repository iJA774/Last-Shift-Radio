[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$testsDirectory = Split-Path -LiteralPath $PSScriptRoot
$projectRoot = Split-Path -LiteralPath $testsDirectory
$godotConsole = 'E:\GAME\Godot_v4.7.1-stable_win64.exe\Godot_v4.7.1-stable_win64_console.exe'
$temporaryBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$smokeAppData = [System.IO.Path]::GetFullPath((Join-Path -Path $temporaryBase -ChildPath 'last_shift_radio_bgm_player_smoke'))

if (-not $smokeAppData.StartsWith($temporaryBase, [System.StringComparison]::OrdinalIgnoreCase)) {
	throw "拒绝清理临时目录外的路径：$smokeAppData"
}

if (Test-Path -LiteralPath $smokeAppData) {
	Remove-Item -LiteralPath $smokeAppData -Recurse -Force
}
New-Item -ItemType Directory -Path $smokeAppData | Out-Null

$previousAppData = $env:APPDATA
try {
	$env:APPDATA = $smokeAppData
	& $godotConsole --headless --path $projectRoot --script res://tests/smoke/test_bgm_player.gd
	if ($LASTEXITCODE -ne 0) {
		throw "BgmPlayer 专项测试失败，退出码：$LASTEXITCODE"
	}
}
finally {
	$env:APPDATA = $previousAppData
	if (Test-Path -LiteralPath $smokeAppData) {
		Remove-Item -LiteralPath $smokeAppData -Recurse -Force
	}
}
