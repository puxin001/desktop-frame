# 备选方案：在桌面建一个真实文件夹，把其他盘的目录以「目录联接」接进来。
# 优点：零常驻程序，双击就是资源管理器原生体验。
# 用法：双击 run_make_box.bat，或 powershell -File make_box.ps1

$OutputEncoding = [Console]::OutputEncoding = [Text.Encoding]::UTF8

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # 上一层是程序根目录
$cfgPath = Join-Path $root 'app\config.json'
$desktop = [Environment]::GetFolderPath('Desktop')
$box = Join-Path $desktop '桌面框'

if (-not (Test-Path -LiteralPath $box)) {
    New-Item -ItemType Directory -Path $box -Force | Out-Null
    Write-Output ('已创建文件夹：' + $box)
}

if (-not (Test-Path -LiteralPath $cfgPath)) {
    Write-Output '缺少 config.json，请先在桌面框程序里添加来源目录。'
    exit 1
}

try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Output ('config.json 解析失败：' + $_.Exception.Message)
    exit 1
}

$made = 0
$skipped = 0

foreach ($s in @($cfg.sources)) {
    if (-not $s) { continue }
    if (-not $s.PSObject.Properties['path'] -or -not $s.path) { continue }
    $target = [string]$s.path
    $name = if ($s.PSObject.Properties['name'] -and $s.name) { [string]$s.name } else { Split-Path -Leaf $target }

    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        Write-Output ('跳过（源目录不存在）：' + $target)
        $skipped++
        continue
    }

    $link = Join-Path $box $name
    if (Test-Path -LiteralPath $link) {
        Write-Output ('跳过（同名已存在）：' + $name)
        $skipped++
        continue
    }

    try {
        New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
        Write-Output ('已联接：' + $name + '  ->  ' + $target)
        $made++
    } catch {
        try {
            $ws = New-Object -ComObject WScript.Shell
            $lnk = $ws.CreateShortcut($link + '.lnk')
            $lnk.TargetPath = $target
            $lnk.WorkingDirectory = $target
            $lnk.Save()
            Write-Output ('已用快捷方式替代：' + $name + '.lnk')
            $made++
        } catch {
            Write-Output ('失败：' + $name + ' - ' + $_.Exception.Message)
            $skipped++
        }
    }
}

Write-Output ''
Write-Output ('完成：新建 ' + $made + ' 个，跳过 ' + $skipped + ' 个')
Write-Output ('位置：' + $box)
