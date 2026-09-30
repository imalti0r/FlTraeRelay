# build.ps1 - 构建 FlTraeRelay Release 版本
# 注意：--no-tree-shake-icons 禁用图标字体裁剪。
# Flutter 的 tree-shake 会错误剔除部分 selectedIcon 字形（如 Icons.memory），
# 导致 NavigationRail 选中态图标显示为空白。

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app = Split-Path -Parent $here

& "D:\DevEnv\flutter\bin\flutter.bat" build windows --release --no-tree-shake-icons --suppress-analytics
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "产物: $app\build\windows\x64\runner\Release\"
