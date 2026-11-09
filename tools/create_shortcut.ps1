# 不强行改控制台编码：跟随当前代码页输出，中文才不会变成乱码。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # 上一层是程序根目录
$desktop = [Environment]::GetFolderPath('Desktop')
$vbs = Join-Path $root '启动桌面框.vbs'
$ps1 = Join-Path $root 'app\desktop_box.ps1'

if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) {
    Write-Output '[X] 找不到桌面目录，无法创建快捷方式。'
    exit 1
}
if (-not (Test-Path -LiteralPath $vbs) -or -not (Test-Path -LiteralPath $ps1)) {
    Write-Output '[X] 程序文件不齐：启动桌面框.vbs 或 app\desktop_box.ps1 不存在。'
    Write-Output ('    程序目录：' + $root)
    exit 1
}

$lnkPath = Join-Path $desktop '桌面框.lnk'
$existed = Test-Path -LiteralPath $lnkPath

try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $lnk.Arguments = '"' + $vbs + '"'
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',3'
    $lnk.Description = '桌面框 · 在桌面浏览其他盘里的文件'
    $lnk.WindowStyle = 1
    $lnk.Save()
} catch {
    Write-Output ('[X] 创建快捷方式失败：' + $_.Exception.Message)
    exit 1
}

if (-not (Test-Path -LiteralPath $lnkPath)) {
    Write-Output '[X] 快捷方式没有生成，可能被安全软件拦住了。'
    exit 1
}

if ($existed) {
    Write-Output ('[OK] 已更新桌面快捷方式：' + $lnkPath)
} else {
    Write-Output ('[OK] 已创建桌面快捷方式：' + $lnkPath)
}
Write-Output ('     指向：' + $ps1)
exit 0
