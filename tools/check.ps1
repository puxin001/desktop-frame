# 桌面框 · 环境自检
# 不强行改控制台编码：跟随当前代码页输出，中文才不会变成乱码。

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)   # 上一层是程序根目录
$script:ok = 0
$script:bad = 0

function OK($m) { Write-Host ('  [通过] ' + $m) -ForegroundColor Green; $script:ok++ }
function NO($m) { Write-Host ('  [问题] ' + $m) -ForegroundColor Yellow; $script:bad++ }
function INFO($m) { Write-Host ('  [信息] ' + $m) -ForegroundColor Gray }

Write-Host ''
Write-Host '桌面框 · 环境自检'
Write-Host ('程序目录：' + $root)
Write-Host ''

if ($PSVersionTable.PSVersion.Major -ge 5) {
    OK ('PowerShell ' + $PSVersionTable.PSVersion.ToString())
} else {
    NO ('PowerShell 版本过低：' + $PSVersionTable.PSVersion.ToString() + '，需要 5.1')
}

foreach ($f in @('启动桌面框.vbs', 'app\desktop_box.ps1', 'app\config.json')) {
    if (Test-Path -LiteralPath (Join-Path $root $f)) { OK ('文件存在：' + $f) }
    else { NO ('缺少文件：' + $f) }
}

$cfg = $null
try {
    $cfg = Get-Content -LiteralPath (Join-Path $root 'app\config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    OK 'config.json 可解析'
} catch {
    NO ('config.json 解析失败：' + $_.Exception.Message)
}

if ($cfg) {
    $keys = @($cfg.PSObject.Properties.Name)
    $missing = @()
    foreach ($need in @('title', 'sources', 'window', 'view')) {
        if ($keys -notcontains $need) { $missing += $need }
    }
    if ($missing.Count -eq 0) {
        OK 'config.json 结构完整（title / sources / window / view）'
    } else {
        NO ('config.json 缺少字段：' + ($missing -join '、') + '（打开一次程序会自动补全）')
    }

    if ($keys -contains 'window' -and $cfg.window) {
        $w = $cfg.window.width; $h = $cfg.window.height
        if (($w -is [int] -or $w -is [long]) -and ($h -is [int] -or $h -is [long]) -and $w -ge 300 -and $h -ge 200) {
            OK ('窗口尺寸正常：' + $w + 'x' + $h)
        } else {
            NO ('窗口尺寸异常：' + $w + 'x' + $h + '（会被自动纠正为 580x460）')
        }
    }

    $srcs = @($cfg.sources)
    $real = 0
    foreach ($s in $srcs) { if ($s) { $real++ } }
    INFO ('来源目录数量：' + $real)
    if ($real -eq 0) {
        NO '还没有来源目录（第一次打开会自动弹出设置，也可以把文件夹拖进框）'
    }
    foreach ($s in $srcs) {
        if (-not $s) { continue }
        if (-not $s.PSObject.Properties['path']) { continue }
        if (Test-Path -LiteralPath ([string]$s.path) -PathType Container) {
            OK ('来源可用：' + $s.name + ' -> ' + $s.path)
        } else {
            NO ('来源不可用：' + $s.path)
        }
    }
}

$logFile = Join-Path $root 'app\error.log'
if (Test-Path -LiteralPath $logFile) {
    NO '存在 error.log，说明上次启动出过错，内容如下：'
    Write-Host ''
    Get-Content -LiteralPath $logFile -Raw -Encoding UTF8 | ForEach-Object {
        ($_ -split "`r?`n" | Select-Object -First 12) | ForEach-Object { Write-Host ('        ' + $_) -ForegroundColor DarkYellow }
    }
    Write-Host ''
} else {
    OK '没有 error.log（上次启动正常）'
}

$desktop = [Environment]::GetFolderPath('Desktop')
if (Test-Path -LiteralPath $desktop) { OK ('桌面路径：' + $desktop) } else { NO '找不到桌面路径' }

# 桌面图标是可选项，现在默认用目录里的「启动桌面框.vbs」，桌面上没有图标属于正常。
$lnk = Join-Path $desktop '桌面框.lnk'
if (Test-Path -LiteralPath $lnk) {
    INFO '桌面上有「桌面框」快捷方式（可选，不想要就删掉它）'
} else {
    INFO '桌面上没有快捷方式（正常，直接双击程序目录里的「启动桌面框.vbs」）'
}

try {
    $asm = [System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')
    if ($asm) { OK 'WinForms 可用' } else { NO 'WinForms 不可用' }
} catch {
    NO ('WinForms 加载失败：' + $_.Exception.Message)
}

$tmpLink = Join-Path $env:TEMP ('box_test_' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
try {
    New-Item -ItemType Junction -Path $tmpLink -Target $env:TEMP -ErrorAction Stop | Out-Null
    [System.IO.Directory]::Delete($tmpLink, $false)
    OK '可创建目录联接（备选方案可用）'
} catch {
    NO ('无法创建目录联接：' + $_.Exception.Message)
}

Write-Host ''
Write-Host ('结果：通过 ' + $script:ok + ' 项，问题 ' + $script:bad + ' 项')
if ($script:bad -eq 0) {
    Write-Host '状态：可以正常使用。' -ForegroundColor Green
} else {
    Write-Host '状态：按上面的提示处理后再试。' -ForegroundColor Yellow
}
