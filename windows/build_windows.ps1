# 在仓库根目录运行。先装好 Python 3.12、依赖和 7-Zip。
$ErrorActionPreference = "Stop"
if (-not (Test-Path "windows/main.py")) {
    throw "请在仓库根目录运行：powershell -File windows/build_windows.ps1"
}

$seven = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
if (-not (Test-Path $seven)) {
    throw "找不到 7-Zip。请先安装：https://www.7-zip.org"
}

python -m PyInstaller --noconfirm --windowed --clean --name QingYa `
    --icon "windows/qingya/assets/icon.ico" `
    --distpath "dist/pyi" --workpath "build/pyi" --specpath "build" `
    --add-data "windows/qingya/assets/icon.png;qingya/assets" `
    --hidden-import keyring --hidden-import charset_normalizer `
    --hidden-import py7zr --hidden-import pyzipper `
    --collect-submodules py7zr `
    "windows/main.py"

$stage = "dist/轻压"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item "dist/pyi/QingYa/*" $stage -Recurse
Copy-Item $seven $stage
Copy-Item (Join-Path $env:ProgramFiles "7-Zip\7z.dll") $stage
Copy-Item "windows/先看这里.txt" $stage
Copy-Item "windows/第三方许可.txt" $stage

$zip = "dist/QingYa-Windows-v1.1.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
& $seven a -tzip -mx=7 $zip "./dist/轻压" | Out-Null
Write-Host "已生成 $zip"
