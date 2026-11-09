<#
  桌面框 desktop_box.ps1
  在桌面悬浮一个可拖动、可缩放的窗口，直接浏览其他盘里的文件夹。
  纯 PowerShell 5.1 + Windows Forms，无第三方依赖。

  启动：双击上一层的「启动桌面框.vbs」
  诊断：powershell -NoProfile -ExecutionPolicy Bypass -File app\desktop_box.ps1 -Test
#>
param([switch]$Test, [switch]$SelfCheck, [switch]$Debug)

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $script:Root) { $script:Root = (Get-Location).Path }
$script:ConfigPath = Join-Path $script:Root 'config.json'

# ---------------------------------------------------------------- JSON 读写
function ConvertTo-JsonString {
    param([string]$s)
    $e = $s.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t')
    return '"' + $e + '"'
}

function ConvertTo-JsonText {
    param($Value, [int]$Depth = 0)
    $pad = ' ' * ($Depth * 2)
    $padIn = ' ' * (($Depth + 1) * 2)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
        return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $Value)
    }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [System.Collections.IDictionary]) {
        $parts = @()
        foreach ($k in $Value.Keys) {
            $parts += ($padIn + (ConvertTo-JsonString ([string]$k)) + ': ' + (ConvertTo-JsonText $Value[$k] ($Depth + 1)))
        }
        if ($parts.Count -eq 0) { return '{}' }
        return "{`r`n" + ($parts -join ",`r`n") + "`r`n$pad}"
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $parts = @()
        foreach ($v in $Value) { $parts += ($padIn + (ConvertTo-JsonText $v ($Depth + 1))) }
        if ($parts.Count -eq 0) { return '[]' }
        return "[`r`n" + ($parts -join ",`r`n") + "`r`n$pad]"
    }
    $props = @()
    foreach ($p in $Value.PSObject.Properties) {
        $props += ($padIn + (ConvertTo-JsonString $p.Name) + ': ' + (ConvertTo-JsonText $p.Value ($Depth + 1)))
    }
    if ($props.Count -eq 0) { return '{}' }
    return "{`r`n" + ($props -join ",`r`n") + "`r`n$pad}"
}

function New-DefaultConfig {
    return [pscustomobject]@{
        title   = '桌面框'
        sources = @()
        window  = [pscustomobject]@{
            x = 160; y = 120; width = 580; height = 460
            # 默认不置顶：框要待在「桌面之上、其它窗口之下」这一层。
            # 置顶虽然方便，但会把别的程序弹出的对话框（打开方式 / 属性 / 保存）压在下面。
            topmost = $false; zorder = 'desktop'; opacity = 0.78; locked = $false
            # 每个分区上次被拖成多高（path → h）。空数组 = 全部按内容自适应。
            # 必须在这里先声明：pscustomobject 不允许事后加属性。
            blockHeights = @()
        }
        view    = [pscustomobject]@{ showHidden = $false; iconSize = 48 }
    }
}

function Read-Config {
    $cfg = New-DefaultConfig
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) { return $cfg }
    try {
        $raw = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8
        if (-not $raw) { return $cfg }
        $j = $raw | ConvertFrom-Json
    } catch { return $cfg }
    if ($null -eq $j) { return $cfg }
    if ($j.PSObject.Properties['title'] -and $j.title) { $cfg.title = [string]$j.title }
    if ($j.PSObject.Properties['sources']) {
        $list = @()
        foreach ($s in @($j.sources)) {
            if (-not $s) { continue }
            if (-not $s.PSObject.Properties['path']) { continue }
            if (-not $s.path) { continue }
            $name = if ($s.PSObject.Properties['name'] -and $s.name) { [string]$s.name } else { Split-Path -Leaf ([string]$s.path) }
            $list += [pscustomobject]@{ name = $name; path = ([string]$s.path) }
        }
        $cfg.sources = $list
    }
    if ($j.PSObject.Properties['window'] -and $j.window) {
        foreach ($k in @('x', 'y', 'width', 'height', 'topmost', 'opacity', 'locked')) {
            if (-not $j.window.PSObject.Properties[$k]) { continue }
            $v = $j.window.$k
            if ($null -eq $v) { continue }
            if ($k -eq 'topmost' -or $k -eq 'locked') {
                if ($v -is [bool]) { $cfg.window.$k = $v }
                continue
            }
            # 只接受真正的数字，字符串 / 布尔 / 对象一律忽略
            if ($v -is [int] -or $v -is [long] -or $v -is [double] -or $v -is [single] -or $v -is [decimal]) {
                $cfg.window.$k = $v
            }
        }
        # 尺寸兜底：防止配置里出现 0 或负数导致窗口不可见
        # 下限必须和 form.MinimumSize 一致，否则用户好不容易拉窄的窗口下次启动会被弹回大尺寸
        if ($cfg.window.width -lt 420) { $cfg.window.width = 520 }
        if ($cfg.window.height -lt 200) { $cfg.window.height = 460 }
        $op = [double]$cfg.window.opacity
        if ($op -lt 0.4 -or $op -gt 1) { $cfg.window.opacity = 0.78 }

        # 老配置没有 zorder 这个字段：说明是「默认置顶」那个版本留下来的，
        # 一律退回桌面层（桌面之上、其它窗口之下）。用户之后在右键菜单里
        # 重新勾「窗口置顶」会写进 zorder，不会被这次迁移再冲掉。
        if (-not $j.window.PSObject.Properties['zorder']) {
            $cfg.window.topmost = $false
            $cfg.window.zorder = 'desktop'
        }

        # 分区高度：老配置没有这一项就保持空数组（全按自适应）
        if ($j.window.PSObject.Properties['blockHeights']) {
            $bh = @()
            foreach ($e in @($j.window.blockHeights)) {
                if (-not $e) { continue }
                if (-not $e.PSObject.Properties['path']) { continue }
                if (-not $e.PSObject.Properties['h']) { continue }
                $bp = [string]$e.path
                if (-not $bp) { continue }
                $bhv = 0
                try { $bhv = [int]$e.h } catch { continue }
                $bh += [pscustomobject]@{ path = $bp; h = $bhv }
            }
            $cfg.window.blockHeights = $bh
        }
    }
    if ($j.PSObject.Properties['view'] -and $j.view) {
        foreach ($k in @('showHidden', 'iconSize')) {
            if (-not $j.view.PSObject.Properties[$k]) { continue }
            $v = $j.view.$k
            if ($k -eq 'showHidden' -and $v -is [bool]) { $cfg.view.showHidden = $v }
            if ($k -eq 'iconSize' -and ($v -is [int] -or $v -is [long])) { $cfg.view.iconSize = [int]$v }
        }
    }
    return $cfg
}

function Save-Config {
    param($cfg)
    # 只按白名单写字段。不直接把 $cfg 丢给序列化器，
    # 避免任何意外对象（例如 Drawing.Color）混进配置文件把整份配置写坏。
    try {
        $srcList = @()
        foreach ($s in @($cfg.sources)) {
            if (-not $s) { continue }
            $p = [string]$s.path
            if (-not $p) { continue }
            $n = [string]$s.name
            if (-not $n) { $n = Split-Path -Leaf $p }
            $srcList += [ordered]@{ name = $n; path = $p }
        }

        $op = 0.78
        if ($cfg.window.opacity -is [double] -or $cfg.window.opacity -is [single] -or $cfg.window.opacity -is [int]) {
            $op = [double]$cfg.window.opacity
        }
        if ($op -lt 0.4) { $op = 0.4 }
        if ($op -gt 1) { $op = 1 }

        # 分区高度（用户拖过的那种）：只留 path + 合理区间内的整数
        # 注意 Save-Config 可能在 $script:BlockMinH 赋值之前就被调用（配置迁移），
        # 所以这里给个兜底值，别指望那个变量一定在。
        $minBlockH = 92
        try { if ($script:BlockMinH) { $minBlockH = [int]$script:BlockMinH } } catch { }
        $bhList = @()
        foreach ($e in @($cfg.window.blockHeights)) {
            if (-not $e) { continue }
            $bp = [string]$e.path
            if (-not $bp) { continue }
            $bh = 0
            try { $bh = [int]$e.h } catch { continue }
            if ($bh -lt $minBlockH -or $bh -gt 4000) { continue }
            $bhList += [ordered]@{ path = $bp; h = $bh }
        }

        $clean = [ordered]@{
            title   = [string]$cfg.title
            sources = $srcList
            window  = [ordered]@{
                x       = [int]$cfg.window.x
                y       = [int]$cfg.window.y
                width   = [int]$cfg.window.width
                height  = [int]$cfg.window.height
                topmost = [bool]$cfg.window.topmost
                zorder  = $(if ($cfg.window.topmost) { 'top' } else { 'desktop' })
                opacity = $op
                locked  = [bool]$cfg.window.locked
                blockHeights = $bhList
            }
            view    = [ordered]@{
                showHidden = [bool]$cfg.view.showHidden
                iconSize   = [int]$cfg.view.iconSize
            }
        }

        $text = ConvertTo-JsonText $clean 0
        # 写盘前先自己解析一遍，解析不了就不落盘（宁可保留旧配置，也不留坏文件）
        $null = $text | ConvertFrom-Json

        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($script:ConfigPath, $text, $enc)
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------- 诊断模式
if ($Test) {
    $cfg = Read-Config
    $mode = if ($cfg.sources.Count -gt 0) { 'sources' } else { 'empty-sources' }
    Write-Output ('CONFIG=' + $script:ConfigPath)
    Write-Output ('TITLE=' + $cfg.title)
    Write-Output ('SOURCES=' + $cfg.sources.Count)
    foreach ($s in $cfg.sources) {
        $ok = Test-Path -LiteralPath $s.path -PathType Container
        $flag = $(if ($ok) { 'OK' } else { 'MISSING' })
        Write-Output ('  ' + $flag + ' | ' + $s.name + ' | ' + $s.path)
    }
    $json = ConvertTo-JsonText $cfg 0
    Write-Output ('JSON_LENGTH=' + $json.Length)
    try {
        $null = $json | ConvertFrom-Json
        Write-Output 'JSON_ROUNDTRIP=OK'
    } catch {
        Write-Output ('JSON_ROUNDTRIP=FAIL ' + $_.Exception.Message)
    }
    Write-Output ('WINDOW=' + $cfg.window.width + 'x' + $cfg.window.height + ' topmost=' + $cfg.window.topmost + ' opacity=' + $cfg.window.opacity)
    Write-Output ('MODE=' + $mode)
    exit 0
}

# ---------------------------------------------------------------- 单实例开关
# 再次双击桌面图标时，不重复起进程，只让正在运行的框显示 / 隐藏。
$script:ToggleFlag = Join-Path $script:Root '.toggle'

# 上一次进程若是被强制结束，Mutex 会处于「已放弃」状态，
# 此时 WaitOne 会抛 AbandonedMutexException —— 必须当成「我是第一个」来处理，
# 否则双击图标会静默失败（什么都不出现）。
$isFirstInstance = $true
$script:InstanceMutex = $null
try {
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\DesktopBox_SingleInstance')
    $isFirstInstance = $script:InstanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    $isFirstInstance = $true
} catch {
    $isFirstInstance = $true
}

if (-not $isFirstInstance) {
    # 已有窗口在跑：只写一个标志文件，让它自己切换显示 / 隐藏
    try { [System.IO.File]::WriteAllText($script:ToggleFlag, '1') } catch { }
    exit 0
}

# ---------------------------------------------------------------- 界面
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$iconCode = @'
using System;
using System.Drawing;
using System.Runtime.InteropServices;

public static class ShellIcon
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    public const uint SHGFI_ICON = 0x100;
    public const uint SHGFI_LARGEICON = 0x0;
    public const uint SHGFI_SMALLICON = 0x1;
    public const uint SHGFI_USEFILEATTRIBUTES = 0x10;
    public const uint SHGFI_TYPENAME = 0x400;
    public const uint FILE_ATTRIBUTE_DIRECTORY = 0x10;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    public static Icon Get(string path, bool isDir, bool small)
    {
        SHFILEINFO info = new SHFILEINFO();
        uint attr = isDir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        uint sizeFlag = small ? SHGFI_SMALLICON : SHGFI_LARGEICON;
        IntPtr r = SHGetFileInfo(path, attr, ref info, (uint)Marshal.SizeOf(info),
            SHGFI_ICON | sizeFlag | SHGFI_USEFILEATTRIBUTES);
        if (r == IntPtr.Zero || info.hIcon == IntPtr.Zero) return null;
        Icon ic = (Icon)Icon.FromHandle(info.hIcon).Clone();
        DestroyIcon(info.hIcon);
        return ic;
    }

    // 「类型」列：交给系统返回本地化名称（文件夹 / 文本文档 / 应用程序 …）
    public static string GetTypeName(string path, bool isDir)
    {
        SHFILEINFO info = new SHFILEINFO();
        uint attr = isDir ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL;
        IntPtr r = SHGetFileInfo(path, attr, ref info, (uint)Marshal.SizeOf(info),
            SHGFI_TYPENAME | SHGFI_USEFILEATTRIBUTES);
        if (r == IntPtr.Zero || string.IsNullOrEmpty(info.szTypeName))
            return isDir ? "文件夹" : "文件";
        return info.szTypeName;
    }
}
'@
try {
    Add-Type -TypeDefinition $iconCode -ReferencedAssemblies 'System.Drawing' -ErrorAction Stop
} catch {
    $iconCode = $null
}

[System.Windows.Forms.Application]::EnableVisualStyles()

# 界面线程里的异常默认会弹 .NET 的对话框甚至让窗口直接消失，
# 这里统一截住写进 error.log，用户至少知道出了什么事。
$script:ErrorLog = Join-Path $script:Root 'error.log'
# 只有正式启动才清掉上一轮的错误日志；跑自检时保留，免得把故障证据抹掉。
if (-not $SelfCheck -and -not $Test) {
    if (Test-Path -LiteralPath $script:ErrorLog) {
        try { Remove-Item -LiteralPath $script:ErrorLog -Force -ErrorAction SilentlyContinue } catch { }
    }
}
try {
    [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
    [System.Windows.Forms.Application]::add_ThreadException({
        param($exSender, $exArgs)
        try {
            $m = ('[UI] ' + $exArgs.Exception.ToString())
            [IO.File]::WriteAllText($script:ErrorLog, $m, (New-Object Text.UTF8Encoding($true)))
        } catch { }
        try {
            [Windows.Forms.MessageBox]::Show(('桌面框遇到一个错误：' + "`r`n" + $exArgs.Exception.Message + "`r`n`r`n详细信息见 error.log"), '桌面框', 'OK', 'Error') | Out-Null
        } catch { }
    })
} catch { }

$script:AppCfg = Read-Config
# 自检会真的走一遍「保存配置」，绝不能写到用户的 config.json 上：
# 读写路径分家 —— 已经按真配置读完了，从这里开始把写入目标换成临时文件。
if ($SelfCheck) {
    $script:ConfigRealPath = $script:ConfigPath
    $script:ConfigPath = Join-Path $env:TEMP ('desktop_box_selfcheck_' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
}
# 逐项重建来源列表：配置里若混入空元素，@(空) 会得到一个「看起来有 1 项」的数组，
# 启动时就会去打开一个不存在的目录，结果是一个纯空白窗口。
$script:Sources = @()
foreach ($s in @($script:AppCfg.sources)) {
    if ($null -eq $s) { continue }
    if (-not $s.path) { continue }
    $n = [string]$s.name
    if (-not $n) { $n = Split-Path -Leaf ([string]$s.path) }
    $script:Sources += [pscustomobject]@{ name = $n; path = ([string]$s.path) }
}
$script:AppCfg.sources = $script:Sources

# 每个分区上次被拖成多高（path → 像素）。空着就全按内容自适应。
# 单独放一张表，是为了「同一次运行里换视图 / 重建分区」也不会把用户刚拖的高度丢掉。
$script:BlockHeights = @{}
foreach ($e in @($script:AppCfg.window.blockHeights)) {
    if (-not $e) { continue }
    if (-not $e.path) { continue }
    $hp = [string]$e.path
    $hv = 0
    try { $hv = [int]$e.h } catch { continue }
    if ($hv -ge 92 -and $hv -le 4000) { $script:BlockHeights[$hp] = $hv }
}

$script:History = New-Object System.Collections.Stack
$script:CurrentSource = $null
$script:CurrentPath = ''
$script:Collapsed = $false
$script:SortCol = 0
$script:SortAsc = $true
$script:ExpandedHeight = [int]$script:AppCfg.window.height
$script:Locked = [bool]$script:AppCfg.window.locked
$script:Dragging = $false
$script:DragX = 0
$script:DragY = 0

$clrBg = [Drawing.ColorTranslator]::FromHtml('#FBFAF7')
$clrFg = [Drawing.ColorTranslator]::FromHtml('#17212B')
$clrMuted = [Drawing.ColorTranslator]::FromHtml('#8A94A3')
$clrAccent = [Drawing.ColorTranslator]::FromHtml('#1F6F5C')
$clrLine = [Drawing.ColorTranslator]::FromHtml('#E6E3DC')
$clrAccentSoft = [Drawing.ColorTranslator]::FromHtml('#9BBCB0')
$clrHover = [Drawing.ColorTranslator]::FromHtml('#EFEDE7')
$clrBorder = [Drawing.ColorTranslator]::FromHtml('#D6D2CA')
$clrSoft = [Drawing.ColorTranslator]::FromHtml('#F3F1EA')

$fontTitle = New-Object Drawing.Font('Microsoft YaHei UI', 10.5, [Drawing.FontStyle]::Bold)
$fontBody = New-Object Drawing.Font('Microsoft YaHei UI', 9)
$fontSmall = New-Object Drawing.Font('Microsoft YaHei UI', 8)
$fontIcon = New-Object Drawing.Font('Segoe UI Symbol', 11)
$fontBlockTitle = New-Object Drawing.Font('Microsoft YaHei UI', 9.5, [Drawing.FontStyle]::Bold)
$fontArrow = New-Object Drawing.Font('Segoe UI Symbol', 8)

function Set-RoundedRegion {
    try {
        $w = $form.Width; $h = $form.Height
        if ($w -lt 40 -or $h -lt 40) { return }
        $r = 10; $d = $r * 2
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
        $p.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
        $p.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
        $p.CloseFigure()
        $form.Region = New-Object Drawing.Region($p)
        $p.Dispose()
    } catch { }
}

function Update-Layout {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    # 顶上那行「路径条」已经去掉：每个分区标题右边本来就写着目录，重复一遍没必要。
    # 标题行直接顶到窗口最上沿，内容区跟着往上提一行。
    $script:pnlTitle.SetBounds(1, 1, $w - 2, 38)
    # 右侧按钮一共四个：× — ⟳ ⚙ 固，从右往左每 32px 一个，共占 186px
    $script:lblTitle.SetBounds(36, 0, [Math]::Max(40, $w - 36 - 190), 38)
    $script:btnBack.SetBounds(6, 7, 24, 24)
    $script:btnClose.Location = New-Object Drawing.Point(($w - 2 - 30), 7)
    $script:btnCollapse.Location = New-Object Drawing.Point(($w - 2 - 60), 7)
    $script:btnRefresh.Location = New-Object Drawing.Point(($w - 2 - 92), 7)
    $script:btnSettings.Location = New-Object Drawing.Point(($w - 2 - 124), 7)
    if ($script:btnLock) { $script:btnLock.Location = New-Object Drawing.Point(($w - 2 - 156), 7) }

    $tabsTop = 39
    # 标签栏已经取消，分区视图直接一屏列全，这里不再给它留高度
    $tabsH = 0
    $script:pnlTabs.Visible = $false
    $script:pnlTabs.SetBounds(1, $tabsTop, $w - 2, 1)
    $statusH = 24
    $bodyTop = $tabsTop + $tabsH
    $bodyH = [Math]::Max(40, $h - $bodyTop - $statusH - 1)

    if (-not $script:Collapsed) {
        $script:lv.SetBounds(1, $bodyTop, $w - 2, $bodyH)
        if ($script:pnlBody) { $script:pnlBody.SetBounds(1, $bodyTop, $w - 2, $bodyH) }
        $script:lblStatus.SetBounds(1, $h - $statusH - 1, $w - 2, $statusH)
    }
    $script:pnlEmpty.SetBounds(1, $bodyTop, $w - 2, $bodyH)

    if ($script:pnlBody -and $script:pnlBody.Visible) { Update-BlockLayout }

    if ($script:pnlEmpty.Visible) {
        $cx = [int](($w - 2) / 2)
        $script:lblEmpty1.SetBounds(1, 34, $w - 2, 28)
        $script:lblEmpty2.SetBounds(1, 64, $w - 2, 26)
        $script:btnAdd.Location = New-Object Drawing.Point(($cx - 70), 112)
        $script:btnCfg.Location = New-Object Drawing.Point(($cx - 70), 156)
    }

    # 四边四角的调大小手柄永远贴着窗口外框
    if ($script:Edges) {
        try { Place-ResizeHandles } catch { }
    }

    Set-RoundedRegion
}

function Format-FileSize {
    param($Length)
    if ($null -eq $Length) { return '' }
    try {
        $v = [double]$Length
    } catch { return '' }
    if ($v -lt 1024) { return ([int]$v).ToString() + ' B' }
    if ($v -lt 1048576) { return [string]::Format('{0:0.0} KB', $v / 1024) }
    if ($v -lt 1073741824) { return [string]::Format('{0:0.0} MB', $v / 1048576) }
    return [string]::Format('{0:0.00} GB', $v / 1073741824)
}

function Fit-Columns {
    # 只剩「名称」一列，让它占满可用宽度
    try {
        $lv = $script:lv
        if ($lv.Columns.Count -lt 1) { return }
        $total = $lv.ClientSize.Width
        if ($total -lt 120) { return }
        $lv.Columns[0].Width = $total - 4
    } catch { }
}

function Sort-ListForView {
    param($List)
    $asc = [bool]$script:SortAsc
    $dirFirst = { if ($_.PSIsContainer) { 0 } else { 1 } }
    $byName = { $_.Name.ToLower() }
    return @($List | Sort-Object @{ Expression = $dirFirst }, @{ Expression = $byName; Ascending = $asc })
}

function Get-ChildrenOf {
    param([string]$Path)
    if ($script:AppCfg.view.showHidden) {
        return @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    }
    return @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)
}

function Get-ForeignPaths {
    # 从拖进来的路径里剔掉「本来就在这个目录里」的那些。
    # 用户误触发的拖拽基本都是原地松手，全部剔完就该什么都不发生。
    param([string[]]$Paths, [string]$Dir)

    $out = @()
    if (-not $Dir) { return @($Paths | Where-Object { $_ }) }
    $d = ([string]$Dir).TrimEnd('\')
    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        $parent = Split-Path -Parent ([string]$p)
        if ($parent) { $parent = $parent.TrimEnd('\') }
        if ($parent -ne $d) { $out += $p }
    }
    return @($out)
}

function Update-SelectionInfo {
    # 点击（选中）一项时，把左下角那行换成这一项的大小和修改时间。
    # 多选就报个数（否则会一直挂着上一项的信息，容易看错）；没选中就保持原样，
    # 不去抢「N 项 · M 个文件夹」那行版面统计。
    param($List)
    if (-not $List) { return }

    $n = 0
    try { $n = $List.SelectedItems.Count } catch { return }

    if ($n -eq 0) { return }
    if ($n -gt 1) {
        $script:lblStatus.Text = ('已选中 ' + $n + ' 项')
        return
    }

    $t = $List.SelectedItems[0].Tag
    if (-not $t -or -not $t.Path) { return }
    $path = $t.Path

    try {
        if ($t.IsDir) {
            $di = New-Object System.IO.DirectoryInfo($path)
            $script:lblStatus.Text = ('文件夹 · 修改于 ' + $di.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
        } else {
            $fi = New-Object System.IO.FileInfo($path)
            $script:lblStatus.Text = ((Format-FileSize $fi.Length) + ' · 修改于 ' + $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))
        }
    } catch { }
}

# ---------------------------------------------------------------- 分区块
$script:BlockHeaderH = 28
$script:BlockGripH = 6
$script:BlockMinH = 92
$script:Blocks = @()
$script:ResizeBlock = $null

function Add-ListRow {
    # 往指定 ListView 里加一行：文件/文件夹，或一行灰字提示
    param($List, $Item, [string]$Text)

    if (-not $List) { return $false }

    if ($Item) {
        $isDir = [bool]$Item.PSIsContainer
        $key = '.file'
        if ($isDir) { $key = '.dir' }
        elseif ($Item.Extension) { $key = $Item.Extension.ToLower() }

        $imgList = $script:imgSmall
        if ($imgList -and -not $imgList.Images.ContainsKey($key)) {
            $bmp = $null
            try {
                if ($iconCode) {
                    $ic = [ShellIcon]::Get($Item.FullName, $isDir, $true)
                    if ($ic) { $bmp = $ic.ToBitmap(); $ic.Dispose() }
                }
            } catch { $bmp = $null }
            if (-not $bmp) { $bmp = New-Object Drawing.Bitmap 16, 16 }
            $imgList.Images.Add($key, $bmp)
        }

        $li = New-Object Windows.Forms.ListViewItem($Item.Name)
        $li.ImageKey = $key
        $li.Tag = [pscustomobject]@{ Path = $Item.FullName; IsDir = $isDir }
        [void]$List.Items.Add($li)
        return $isDir
    }

    $li = New-Object Windows.Forms.ListViewItem([string]$Text)
    $li.ForeColor = $clrMuted
    $li.Tag = $null
    [void]$List.Items.Add($li)
    return $false
}

function Fill-List {
    # 注意：参数名不能叫 $List 又在函数里写 $list —— PowerShell 变量名不区分大小写，
    # 两个会变成同一个变量，列表对象就会被目录项数组顶掉。
    param($List, [string]$Path)

    $List.BeginUpdate()
    try {
        $List.Items.Clear()
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) {
            Add-ListRow -List $List -Text '（这个分区现在打不开，盘没插或路径改了）' | Out-Null
            return 0
        }
        $entries = @(Get-ChildrenOf $Path)
        $entries = Sort-ListForView $entries
        if ($entries.Count -eq 0) {
            Add-ListRow -List $List -Text '（空文件夹）' | Out-Null
            return 0
        }
        $n = 0
        foreach ($entry in $entries) {
            Add-ListRow -List $List -Item $entry | Out-Null
            $n++
        }
        return $n
    } finally {
        $List.EndUpdate()
    }
}

function Update-BlockLayout {
    $body = $script:pnlBody
    if (-not $body) { return }

    # AutoScroll 容器有个坑：在「已滚动」状态下给子控件 SetBounds，
    # 坐标会被按滚动量折算进虚拟坐标里；等滚动归零，控件就永久停在下方。
    # 表现就是用户看到的「标题栏下面到第一个分区之间一大片空白」。
    # 实测：滚 120px 时布局一次，滚动归零后第一块从 y=0 变成 y=120。
    # 所以：布局前把滚动量归零，摆完再按需还原。
    $keepY = 0
    try { $keepY = [Math]::Abs($body.AutoScrollPosition.Y) } catch { }
    if ($keepY -gt 0) {
        try { $body.AutoScrollPosition = New-Object Drawing.Point(0, 0) } catch { }
    }

    $total = 0
    foreach ($b in $script:Blocks) {
        if ($b.Collapsed) { $total += $script:BlockHeaderH } else { $total += $b.Height }
    }

    $needScroll = ($total -gt $body.ClientSize.Height)
    $w = $body.ClientSize.Width
    if ($needScroll) { $w = [Math]::Max(140, $w - 18) }

    $y = 0
    foreach ($b in $script:Blocks) {
        $h = if ($b.Collapsed) { $script:BlockHeaderH } else { $b.Height }
        $b.Panel.SetBounds(0, $y, $w, $h)
        $b.Header.SetBounds(0, 0, $w, $script:BlockHeaderH)

        $b.Arrow.SetBounds(5, 3, 20, 22)
        $b.NewBtn.SetBounds([Math]::Max(20, $w - 28), 3, 22, 22)

        $tw = $b.TitleW
        $b.TitleLabel.SetBounds(26, 0, $tw, $script:BlockHeaderH)
        $pathW = [Math]::Max(30, $w - (26 + $tw + 8) - 34)
        $b.PathLabel.SetBounds(26 + $tw + 8, 0, $pathW, $script:BlockHeaderH)

        if ($b.Collapsed) {
            $b.List.Visible = $false
            $b.Grip.Visible = $false
        } else {
            $b.List.Visible = $true
            $b.Grip.Visible = $true
            $b.List.SetBounds(0, $script:BlockHeaderH, $w, [Math]::Max(20, $h - $script:BlockHeaderH - $script:BlockGripH))
            $b.Grip.SetBounds(0, $h - $script:BlockGripH, $w, $script:BlockGripH)
            try { $b.List.Columns[0].Width = [Math]::Max(80, $b.List.ClientSize.Width - 4) } catch { }
        }
        $y += $h
    }
    $body.AutoScrollMinSize = New-Object Drawing.Size(0, $y)

    # 滚动量不超过内容能滚的范围；内容变少（例如全部收起）就自动回到顶部
    $maxY = [Math]::Max(0, $y - $body.ClientSize.Height)
    if ($keepY -gt $maxY) { $keepY = $maxY }
    if ($keepY -gt 0) {
        try { $body.AutoScrollPosition = New-Object Drawing.Point(0, $keepY) } catch { }
    }
}

# 点分区标题 = 折叠 / 展开
$script:ToggleBlock = {
    $b = $this.Tag
    if (-not $b) { $b = $this.Parent.Tag }
    if (-not $b) { return }
    $b.Collapsed = -not $b.Collapsed
    if ($b.Arrow) { $b.Arrow.Text = $(if ($b.Collapsed) { '▶' } else { '▼' }) }
    Update-BlockLayout
}

function Test-CanResizeBlock {
    # 分区高度和「固定」无关：固定只锁窗口位置，横条什么时候都能拖。
    # 保留这个函数是为了让自检有个明确的判断点（不用去模拟鼠标事件）。
    return $true
}

function New-Block {
    param($Source, [int]$Height = 200, [bool]$Collapsed = $false)

    $name = [string]$Source.name
    if (-not $name) { $name = [string]$Source.path }

    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $clrBg

    $hd = New-Object Windows.Forms.Panel
    $hd.BackColor = $clrSoft
    $p.Controls.Add($hd)

    $arrow = New-Object Windows.Forms.Label
    $arrow.Font = $fontArrow
    $arrow.TextAlign = 'MiddleCenter'
    $arrow.ForeColor = $clrMuted
    $arrow.Cursor = 'Hand'
    $hd.Controls.Add($arrow)

    $title = New-Object Windows.Forms.Label
    $title.Font = $fontBlockTitle
    $title.Text = $name
    $title.TextAlign = 'MiddleLeft'
    $title.ForeColor = $clrFg
    $title.Cursor = 'Hand'
    $hd.Controls.Add($title)

    $pl = New-Object Windows.Forms.Label
    $pl.Font = $fontSmall
    $pl.Text = [string]$Source.path
    $pl.TextAlign = 'MiddleLeft'
    $pl.ForeColor = $clrMuted
    $pl.AutoEllipsis = $true
    $pl.Cursor = 'Hand'
    $hd.Controls.Add($pl)

    $nb = New-Object Windows.Forms.Label
    $nb.Text = '＋'
    $nb.Font = $fontIcon
    $nb.TextAlign = 'MiddleCenter'
    $nb.ForeColor = $clrMuted
    $nb.Cursor = 'Hand'
    $hd.Controls.Add($nb)

    # 分区内部自己带滚动条，内容多就在块内滚
    $lv = New-Object Windows.Forms.ListView
    $lv.View = 'Details'
    $lv.BorderStyle = 'None'
    $lv.BackColor = $clrBg
    $lv.ForeColor = $clrFg
    $lv.Font = $fontBody
    $lv.FullRowSelect = $true
    $lv.MultiSelect = $true
    $lv.HideSelection = $false
    $lv.GridLines = $false
    $lv.HeaderStyle = 'None'
    $lv.ShowItemToolTips = $true
    $lv.SmallImageList = $script:imgSmall
    $lv.AllowDrop = $true
    [void]$lv.Columns.Add('名称', 400, 'Left')
    $p.Controls.Add($lv)

    $gp = New-Object Windows.Forms.Panel
    $gp.Cursor = [Windows.Forms.Cursors]::SizeNS
    $gp.BackColor = $clrLine
    $p.Controls.Add($gp)

    $tw = [Windows.Forms.TextRenderer]::MeasureText($name, $fontBlockTitle).Width + 12

    $b = [pscustomobject]@{
        Panel      = $p
        Header     = $hd
        Arrow      = $arrow
        TitleLabel = $title
        PathLabel  = $pl
        NewBtn     = $nb
        List       = $lv
        Grip       = $gp
        Source     = $Source
        Collapsed  = $Collapsed
        Height     = [Math]::Max($script:BlockMinH, $Height)
        TitleW     = $tw
    }

    $p.Tag = $b
    $hd.Tag = $b
    $lv.Tag = $b
    $gp.Tag = $b

    $arrow.Text = $(if ($Collapsed) { '▶' } else { '▼' })

    $hd.Add_Click($script:ToggleBlock)
    $arrow.Add_Click($script:ToggleBlock)
    $title.Add_Click($script:ToggleBlock)
    $pl.Add_Click($script:ToggleBlock)

    $nb.Add_Click({ New-FolderIn -Dir $this.Parent.Tag.Source.path })
    $nb.Add_MouseEnter({ $this.ForeColor = $clrAccent })
    $nb.Add_MouseLeave({ $this.ForeColor = $clrMuted })

    # 拖底部横条改本分区高度（和「固定」无关，什么时候都能拖）
    $gp.Add_MouseDown({
        $b = $this.Tag
        if (-not $b) { return }
        if (-not (Test-CanResizeBlock)) { return }
        $script:ResizeBlock = $b
        $script:ResizeBlockY = [Windows.Forms.Cursor]::Position.Y
        $script:ResizeBlockH = $b.Height
        $this.BackColor = $clrAccent
        $this.Capture = $true
    })
    $gp.Add_MouseMove({
        if (-not $script:ResizeBlock) { return }
        $dy = [Windows.Forms.Cursor]::Position.Y - $script:ResizeBlockY
        $h = [Math]::Max($script:BlockMinH, $script:ResizeBlockH + $dy)
        if ($h -ne $script:ResizeBlock.Height) {
            $script:ResizeBlock.Height = $h
            Update-BlockLayout
        }
    })
    $gp.Add_MouseUp({
        # 松手就把这个分区的高度记进内存表：换视图、重建分区、退出时都用得上
        if ($script:ResizeBlock) {
            try {
                $rp = [string]$script:ResizeBlock.Source.path
                if ($rp) { $script:BlockHeights[$rp] = [int]$script:ResizeBlock.Height }
            } catch { }
        }
        $script:ResizeBlock = $null
        $this.BackColor = $clrLine
        $this.Capture = $false
    })
    # 这条 6px 的横条就是「拖我改高」的把手，光靠浅色线用户看不出来，给个悬停反馈
    $gp.Add_MouseEnter({ if (-not $script:ResizeBlock) { $this.BackColor = $clrAccentSoft } })
    $gp.Add_MouseLeave({ if (-not $script:ResizeBlock) { $this.BackColor = $clrLine } })

    # 双击 / 快捷键 / 右键菜单：和单目录视图共用同一套处理器
    if ($script:ListDoubleClick) { $lv.Add_DoubleClick($script:ListDoubleClick) }
    if ($script:ListKeyDown) { $lv.Add_KeyDown($script:ListKeyDown) }
    if ($script:ListItemDrag) { $lv.Add_ItemDrag($script:ListItemDrag) }
    if ($script:WheelToList) { $lv.Add_MouseWheel($script:WheelToList) }
    $lv.Add_SelectedIndexChanged({ Update-SelectionInfo -List $this })
    if ($script:ctx) { $lv.ContextMenuStrip = $script:ctx }

    # 从别处拖进这个块 = 复制到本分区目录
    $lv.Add_DragEnter({
        param($dragSender, $dragArgs)
        if ($dragArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
            $dragArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
        } else {
            $dragArgs.Effect = [Windows.Forms.DragDropEffects]::None
        }
    })
    $lv.Add_DragDrop({
        param($dropSender, $dropArgs)
        $b = $this.Tag
        if (-not $b) { return }
        $paths = @($dropArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        if ($paths.Count -eq 0) { return }

        # 拖回它自己所在的分区：什么都不做，也别弹「已复制 0 项」那种提示。
        # 误触发的拖拽大多是原地松手，静默丢掉比报一堆 0 更让人安心。
        $real = @(Get-ForeignPaths -Paths $paths -Dir $b.Source.path)
        if ($real.Count -eq 0) { return }

        Copy-PathsInto -Paths $real -Dest $b.Source.path
    })

    return $b
}

function Get-SavedBlockHeight {
    # 分区高度记在 $script:BlockHeights（path → 像素），启动时从 config 灌进来，
    # 拖动松手时更新，关闭时再写回 config。返回 0 表示「按内容自适应」。
    param([string]$Path)
    if (-not $Path) { return 0 }
    try {
        $tbl = $script:BlockHeights
        if (-not $tbl) { return 0 }
        if (-not $tbl.ContainsKey($Path)) { return 0 }
        $h = [int]$tbl[$Path]
        if ($h -ge $script:BlockMinH -and $h -le 4000) { return $h }
    } catch { }
    return 0
}

function Rebuild-Blocks {
    foreach ($b in $script:Blocks) {
        try { $b.Panel.Dispose() } catch { }
    }
    $script:Blocks = @()

    $body = $script:pnlBody
    if (-not $body) { return }
    # 重建过程中容器会把最后新建的分区滚进视野，重建完要恢复原位（启动时就是回到顶部）
    $keepY = 0
    try { $keepY = [Math]::Abs($body.AutoScrollPosition.Y) } catch { }
    try { $body.Controls.Clear() } catch { }

    $valid = @()
    foreach ($s in $script:Sources) { if ($s.path) { $valid += $s } }
    if ($valid.Count -eq 0) {
        $body.AutoScrollMinSize = New-Object Drawing.Size(0, 0)
        $script:lblStatus.Text = '还没有分区'
        return
    }

    $total = 0
    $dirs = 0
    foreach ($s in $valid) {
        $b = New-Block -Source $s -Height 160
        $n = Fill-List -List $b.List -Path $s.path
        $total += $n
        foreach ($it in $b.List.Items) {
            if ($it.Tag -and $it.Tag.IsDir) { $dirs++ }
        }
        # 高度按内容自适应，最多露 16 行，剩下靠块内滚动
        # 行高不是拍脑袋的 26：ListView 的 Details 行高 = 小图标高 + 上下留白（4px），实测 30。
        # 之前写死 26 会导致最后一行被切掉半个。
        $rows = [Math]::Min($b.List.Items.Count, 16)
        $b.Height = [Math]::Max($script:BlockMinH, $script:BlockHeaderH + 8 + $rows * $script:RowH + $script:BlockGripH)
        # 用户手动拖过的分区高度优先（自适应只当默认值），重启后还是上次那个高度
        $saved = Get-SavedBlockHeight -Path ([string]$s.path)
        if ($saved -gt 0) { $b.Height = $saved }
        $body.Controls.Add($b.Panel)
        $script:Blocks += $b
    }

    Update-BlockLayout
    try { $body.AutoScrollPosition = New-Object Drawing.Point(0, $keepY) } catch { }
    $script:lblStatus.Text = ("{0} 个分区 · {1} 项 · {2} 个文件夹" -f $valid.Count, $total, $dirs)
}

function Show-Overview {
    param([switch]$Rebuild)

    $script:CurrentPath = ''
    $script:History.Clear()
    if ($script:pnlBody) { $script:pnlBody.Visible = $true }
    $script:lv.Visible = $false

    $script:btnBack.ForeColor = $clrLine

    Update-Layout
    if ($Rebuild -or $script:Blocks.Count -ne @($script:Sources | Where-Object { $_.path }).Count) {
        Rebuild-Blocks
    } else {
        Update-BlockLayout
    }
}

function Show-AllSources {
    Show-Overview -Rebuild
}

function Show-Folder {
    param([string]$Path, [switch]$NoHistory)

    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        [Windows.Forms.MessageBox]::Show(("目录不存在或无法访问：`r`n" + $Path), '桌面框', 'OK', 'Warning') | Out-Null
        return
    }
    # 从分区总览进来时把空路径压栈，返回时才知道要回到总览
    if (-not $NoHistory -and $script:CurrentPath -ne $Path) {
        $script:History.Push($script:CurrentPath)
    }
    $script:CurrentPath = $Path

    if ($script:pnlBody) { $script:pnlBody.Visible = $false }
    $script:lv.Visible = $true
    Update-Layout

    $lv = $script:lv
    $lv.BeginUpdate()
    try {
        $lv.Items.Clear()
        $list = @(Get-ChildrenOf $Path)
        $list = Sort-ListForView $list

        $dirCount = 0
        foreach ($item in $list) {
            if (Add-ListRow -List $lv -Item $item) { $dirCount++ }
        }
        $script:lblStatus.Text = ("{0} 项 · {1} 个文件夹" -f $list.Count, $dirCount)
    } catch {
        $script:lblStatus.Text = '读取失败：' + $_.Exception.Message
    } finally {
        $lv.EndUpdate()
    }
    Fit-Columns
    $script:btnBack.ForeColor = if ($script:History.Count -gt 0) { $clrFg } else { $clrLine }
}

# ---------------------------------------------------------------- 新建文件夹
function Show-InputDialog {
    param([string]$Title, [string]$Prompt, [string]$Default = '')

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.ClientSize = New-Object Drawing.Size(430, 152)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $clrBg
    $dlg.Font = $fontBody
    $dlg.TopMost = $true

    $lp = New-Object Windows.Forms.Label
    $lp.Text = $Prompt
    $lp.SetBounds(16, 12, 398, 42)
    $lp.ForeColor = $clrMuted
    $dlg.Controls.Add($lp)

    $tb = New-Object Windows.Forms.TextBox
    $tb.SetBounds(16, 58, 398, 26)
    $tb.Text = $Default
    $tb.Font = $fontBody
    $dlg.Controls.Add($tb)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = '确定'
    $btnOk.SetBounds(222, 104, 88, 30)
    $btnOk.DialogResult = [Windows.Forms.DialogResult]::OK
    $dlg.Controls.Add($btnOk)

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = '取消'
    $btnCancel.SetBounds(322, 104, 88, 30)
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancel
    $tb.SelectAll()

    $r = $dlg.ShowDialog($form)
    $val = $tb.Text
    try { $dlg.Dispose() } catch { }

    if ($r -eq [Windows.Forms.DialogResult]::OK) { return $val }
    return $null
}

function New-FolderIn {
    param([string]$Dir)

    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir -PathType Container)) {
        [Windows.Forms.MessageBox]::Show('这个分区现在打不开，没法在里面新建。', '桌面框', 'OK', 'Warning') | Out-Null
        return
    }

    $name = Show-InputDialog -Title '新建文件夹' -Prompt ('在下面这个位置新建文件夹：' + "`r`n" + $Dir) -Default '新建文件夹'
    if ($null -eq $name) { return }
    $name = $name.Trim()
    if (-not $name) { return }

    if ($name -match '[\\/:*?"<>|]') {
        [Windows.Forms.MessageBox]::Show('名字里不能出现 \ / : * ? " < > | 这些字符。', '桌面框', 'OK', 'Warning') | Out-Null
        return
    }

    $target = Join-Path $Dir $name
    if (Test-Path -LiteralPath $target) {
        [Windows.Forms.MessageBox]::Show('同名文件夹已经存在了。', '桌面框', 'OK', 'Information') | Out-Null
        return
    }

    try {
        New-Item -ItemType Directory -Path $target -ErrorAction Stop | Out-Null
    } catch {
        [Windows.Forms.MessageBox]::Show(('新建失败：' + $_.Exception.Message), '桌面框', 'OK', 'Warning') | Out-Null
        return
    }

    Show-Overview -Rebuild
    $script:lblStatus.Text = '已新建文件夹：' + $name
}

function Refresh-CurrentView {
    if ($script:CurrentPath) { Show-Folder -Path $script:CurrentPath -NoHistory }
    else { Show-Overview -Rebuild }
}

# ---------------------------------------------------------------- 复制 / 粘贴
function Get-UniquePath {
    param([string]$Target, [bool]$IsDir)
    if (-not (Test-Path -LiteralPath $Target)) { return $Target }
    $dir = Split-Path -Parent $Target
    $leaf = Split-Path -Leaf $Target
    if ($IsDir) {
        $base = $leaf; $ext = ''
    } else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
        $ext = [System.IO.Path]::GetExtension($leaf)
        if (-not $base) { $base = $leaf; $ext = '' }
    }
    for ($i = 2; $i -lt 999; $i++) {
        $cand = Join-Path $dir ($base + ' (' + $i + ')' + $ext)
        if (-not (Test-Path -LiteralPath $cand)) { return $cand }
    }
    return (Join-Path $dir ($base + ' (' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + ')' + $ext))
}

function Get-SelectedPaths {
    param($List)
    if (-not $List) { $List = $script:lv }
    $out = @()
    foreach ($it in $List.SelectedItems) {
        if ($it.Tag -and $it.Tag.Path) { $out += $it.Tag.Path }
    }
    return @($out)
}

function New-FileDropDataObject {
    # 造一个「文件拖放」数据对象：1=复制 2=剪切。
    # 单拎出来是为了能直接检查内容 —— 走系统剪贴板再读回来会被剪贴板管理器
    # 之类的东西插一手，自检里那条断言因此时灵时不灵。
    param([string[]]$Paths, [switch]$Move)

    $list = @($Paths | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }

    $dobj = New-Object Windows.Forms.DataObject
    $dobj.SetData([Windows.Forms.DataFormats]::FileDrop, [string[]]$list)

    $effect = 1
    if ($Move) { $effect = 2 }
    $ms = New-Object System.IO.MemoryStream
    $bytes = [BitConverter]::GetBytes([int]$effect)
    $ms.Write($bytes, 0, $bytes.Length)
    $ms.Position = 0
    $dobj.SetData('Preferred DropEffect', $ms)
    return $dobj
}

function Set-ClipboardFiles {
    param([string[]]$Paths, [switch]$Move)
    $dobj = New-FileDropDataObject -Paths $Paths -Move:$Move
    if (-not $dobj) { return $false }
    try {
        [Windows.Forms.Clipboard]::SetDataObject($dobj, $true)
        return $true
    } catch { return $false }
}

function Get-ClipboardDropEffect {
    # 剪贴板里标记的是复制(1)还是剪切(2)。读不到一律按复制处理，宁可多留一份也不误删。
    try {
        if (-not [Windows.Forms.Clipboard]::ContainsData('Preferred DropEffect')) { return 1 }
        $ms = [Windows.Forms.Clipboard]::GetData('Preferred DropEffect')
        if (-not $ms) { return 1 }
        $buf = New-Object byte[] 4
        try { $ms.Position = 0 } catch { }
        $n = $ms.Read($buf, 0, 4)
        if ($n -lt 4) { return 1 }
        return [BitConverter]::ToInt32($buf, 0)
    } catch { return 1 }
}

# ---------------------------------------------------------------- 资源管理器那套操作
# 「属性」窗口只能让 shell 自己弹。ShellExecuteEx + verb=properties 是最省事的路子：
# 不用碰 IContextMenu 的 vtable（那套接口在 PowerShell 里手写极易越界崩溃）。
$script:shellGoCode = @'
using System;
using System.Runtime.InteropServices;

public static class ShellGo
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHELLEXECUTEINFO
    {
        public int cbSize;
        public uint fMask;
        public IntPtr hwnd;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpVerb;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpFile;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpParameters;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpDirectory;
        public int nShow;
        public IntPtr hInstApp;
        public IntPtr lpIDList;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpClass;
        public IntPtr hkeyClass;
        public uint dwHotKey;
        public IntPtr hIcon;
        public IntPtr hProcess;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ShellExecuteEx(ref SHELLEXECUTEINFO sei);

    public static bool Properties(IntPtr hwnd, string path)
    {
        SHELLEXECUTEINFO sei = new SHELLEXECUTEINFO();
        sei.cbSize = Marshal.SizeOf(typeof(SHELLEXECUTEINFO));
        sei.fMask = 0x0000040C;      // SEE_MASK_INVOKEIDLIST | SEE_MASK_FLAG_NO_UI
        sei.hwnd = hwnd;
        sei.lpVerb = "properties";
        sei.lpFile = path;
        sei.nShow = 1;               // SW_SHOWNORMAL
        return ShellExecuteEx(ref sei);
    }
}
'@

function Move-PathsInto {
    param([string[]]$Paths, [string]$Dest, [switch]$Quiet)

    if (-not $Dest -or -not (Test-Path -LiteralPath $Dest -PathType Container)) {
        if (-not $Quiet) {
            [Windows.Forms.MessageBox]::Show('当前没有打开具体文件夹，没地方可移动。', '桌面框', 'OK', 'Information') | Out-Null
        }
        return
    }

    $destFull = [System.IO.Path]::GetFullPath($Dest).TrimEnd('\')
    $ok = 0; $skip = 0; $fail = 0; $lastErr = ''

    if (-not $Quiet) {
        $script:lblStatus.Text = '正在移动…'
        try { [Windows.Forms.Application]::DoEvents() } catch { }
    }

    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) { $fail++; $lastErr = '找不到：' + $p; continue }
        try {
            $srcFull = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
            $srcParent = [System.IO.Path]::GetDirectoryName($srcFull)
            if ($srcParent) { $srcParent = $srcParent.TrimEnd('\') }
            $isDir = Test-Path -LiteralPath $p -PathType Container

            if ($srcParent -eq $destFull) { $skip++; continue }
            if ($isDir -and (($destFull + '\').StartsWith($srcFull + '\'))) { $skip++; continue }

            $target = Join-Path $destFull (Split-Path -Leaf $p)
            $target = Get-UniquePath -Target $target -IsDir $isDir
            Move-Item -LiteralPath $p -Destination $target -Force -ErrorAction Stop
            $ok++
        } catch {
            $fail++
            $lastErr = $_.Exception.Message
        }
    }

    if ($Quiet) { return }
    Refresh-CurrentView

    $msg = '已移动 ' + $ok + ' 项'
    if ($skip -gt 0) { $msg += '，跳过 ' + $skip + ' 项（已在目标里）' }
    if ($fail -gt 0) { $msg += '，失败 ' + $fail + ' 项' }
    $script:lblStatus.Text = $msg
    if ($fail -gt 0) {
        [Windows.Forms.MessageBox]::Show(($msg + "`r`n`r`n最后一个错误：`r`n" + $lastErr), '桌面框', 'OK', 'Warning') | Out-Null
    }
}

function Remove-ToRecycleBin {
    # 走回收站，不直接抹盘。删错了能捞回来。
    param([string[]]$Paths, [switch]$NoConfirm)

    $list = @($Paths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
    if ($list.Count -eq 0) { $script:lblStatus.Text = '没有可删除的项目'; return }

    if (-not $NoConfirm) {
        $names = @()
        foreach ($p in $list) { $names += ('  · ' + (Split-Path -Leaf $p)) }
        if ($names.Count -gt 6) {
            $names = @($names[0..5])
            $names += ('  … 另有 ' + ($list.Count - 6) + ' 项')
        }
        $txt = '确定把这些放进回收站吗？' + "`r`n`r`n" + ($names -join "`r`n")
        $r = [Windows.Forms.MessageBox]::Show($txt, '删除', 'YesNo', 'Question', 'No')
        if ($r -ne [Windows.Forms.DialogResult]::Yes) { return }
    }

    try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }

    $ok = 0; $fail = 0; $lastErr = ''
    foreach ($p in $list) {
        try {
            if (Test-Path -LiteralPath $p -PathType Container) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            } else {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin')
            }
            $ok++
        } catch {
            $fail++
            $lastErr = $_.Exception.Message
        }
    }

    Refresh-CurrentView
    $msg = '已删除 ' + $ok + ' 项（在回收站里）'
    if ($fail -gt 0) { $msg += '，失败 ' + $fail + ' 项' }
    $script:lblStatus.Text = $msg
    if ($fail -gt 0) {
        [Windows.Forms.MessageBox]::Show(($msg + "`r`n`r`n最后一个错误：`r`n" + $lastErr), '桌面框', 'OK', 'Warning') | Out-Null
    }
}

function Rename-Selected {
    param($List)
    if (-not $List) { $List = $script:lv }
    if (-not $List -or $List.SelectedItems.Count -ne 1) {
        $script:lblStatus.Text = '重命名要一次选一个'
        return
    }
    $t = $List.SelectedItems[0].Tag
    if (-not $t -or -not $t.Path) { return }

    $oldPath = $t.Path
    $oldName = Split-Path -Leaf $oldPath
    $isDir = [bool]$t.IsDir

    # 文件的默认文本只给主名（不带扩展名），跟资源管理器一致
    $default = $oldName
    if (-not $isDir) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($oldName)
        if ($base) { $default = $base }
    }

    $newName = Show-InputDialog -Title '重命名' -Prompt ('把「' + $oldName + '」改名成：') -Default $default
    if ($null -eq $newName) { return }
    $newName = $newName.Trim()
    if (-not $newName) { return }
    if ($newName -match '[\\/:*?"<>|]') {
        [Windows.Forms.MessageBox]::Show('名字里不能出现 \ / : * ? " < > | 这些字符。', '桌面框', 'OK', 'Warning') | Out-Null
        return
    }

    if (-not $isDir) {
        $ext = [System.IO.Path]::GetExtension($oldName)
        if ($ext -and -not $newName.ToLower().EndsWith($ext.ToLower())) { $newName += $ext }
    }

    if ($newName -eq $oldName) { return }

    $parent = Split-Path -Parent $oldPath
    $target = Join-Path $parent $newName
    if (Test-Path -LiteralPath $target) {
        [Windows.Forms.MessageBox]::Show('同名的东西已经存在了。', '桌面框', 'OK', 'Information') | Out-Null
        return
    }

    try {
        Rename-Item -LiteralPath $oldPath -NewName $newName -ErrorAction Stop
    } catch {
        [Windows.Forms.MessageBox]::Show(('改名失败：' + $_.Exception.Message), '桌面框', 'OK', 'Warning') | Out-Null
        return
    }

    Refresh-CurrentView
    $script:lblStatus.Text = '已重命名：' + $newName
}

function Get-ShellVerbs {
    # 把这个文件能用的系统动词列出来（打开方式 / 共享 / 压缩 / WinRAR / 属性 …… 第三方扩展也在这里）
    param([string]$Path)
    $out = @()
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    try {
        $dir = Split-Path -Parent $Path
        $leaf = Split-Path -Leaf $Path
        if (-not $dir) { return @() }
        $sh = New-Object -ComObject Shell.Application
        $item = $sh.Namespace($dir).ParseName($leaf)
        if (-not $item) { return @() }
        foreach ($v in $item.Verbs()) {
            $n = [string]$v.Name
            if (-not $n) { continue }
            $n = ($n -replace '&', '').Trim()
            if (-not $n) { continue }
            $out += [pscustomobject]@{ Verb = $v; Name = $n }
        }
    } catch { }
    return @($out)
}

function Invoke-ShellVerbPrefix {
    # 按动词名的前缀去调系统动词（名字是中文的，只能按前缀匹配）
    param([string]$Path, [string]$Prefix)
    foreach ($v in (Get-ShellVerbs -Path $Path)) {
        if ($v.Name.StartsWith($Prefix)) {
            try { $v.Verb.DoIt(); return $true } catch { return $false }
        }
    }
    return $false
}

function Show-ItemProperties {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        if (-not ('ShellGo' -as [type])) { Add-Type -TypeDefinition $script:shellGoCode }
        [ShellGo]::Properties($form.Handle, $Path) | Out-Null
    } catch {
        $script:lblStatus.Text = '打不开属性窗口'
    }
}

function Open-WithDialog {
    param([string]$Path)
    if (-not $Path) { return }
    try {
        $r = Join-Path $env:SystemRoot 'System32\rundll32.exe'
        Start-Process -FilePath $r -ArgumentList 'shell32.dll,OpenAs_RunDLL', $Path
    } catch {
        $script:lblStatus.Text = '打不开「打开方式」'
    }
}

function Copy-SelectedPath {
    param($List)
    # 必须用 @() 包起来：Get-SelectedPaths 里 return @($out) 在只有一个元素时
    # 会被管道拆成裸字符串，$paths[0] 就变成第一个字符（复制出来只有一个「E」）。
    $paths = @(Get-SelectedPaths -List $List)
    if ($paths.Count -eq 0) { $script:lblStatus.Text = '没有选中任何项目'; return }
    try {
        if ($paths.Count -eq 1) { [Windows.Forms.Clipboard]::SetText([string]$paths[0]) }
        else { [Windows.Forms.Clipboard]::SetText(($paths -join "`r`n")) }
        $script:lblStatus.Text = ('已复制 ' + $paths.Count + ' 项的完整路径')
    } catch { $script:lblStatus.Text = '复制路径失败' }
}

function Get-ClipboardFiles {
    try {
        if (-not [Windows.Forms.Clipboard]::ContainsFileDropList()) { return @() }
        return @([Windows.Forms.Clipboard]::GetFileDropList())
    } catch { return @() }
}

function Copy-PathsInto {
    param([string[]]$Paths, [string]$Dest, [switch]$Quiet)

    if (-not $Dest -or -not (Test-Path -LiteralPath $Dest -PathType Container)) {
        if (-not $Quiet) {
            [Windows.Forms.MessageBox]::Show(('当前没有打开具体文件夹。' + "`r`n`r`n" + '如果想把文件夹加成一个新分区，直接把它拖进框就行。'), '桌面框', 'OK', 'Information') | Out-Null
        }
        return
    }

    $destFull = [System.IO.Path]::GetFullPath($Dest).TrimEnd('\')
    $ok = 0; $skip = 0; $fail = 0; $lastErr = ''

    if (-not $Quiet) {
        $script:lblStatus.Text = '正在复制…'
        try { [Windows.Forms.Application]::DoEvents() } catch { }
    }

    foreach ($p in @($Paths)) {
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) { $fail++; $lastErr = '找不到：' + $p; continue }
        try {
            $srcFull = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
            $srcParent = [System.IO.Path]::GetDirectoryName($srcFull)
            if ($srcParent) { $srcParent = $srcParent.TrimEnd('\') }
            $isDir = Test-Path -LiteralPath $p -PathType Container

            # 源已经在目标目录里：跳过，否则会自己复制自己
            if ($srcParent -eq $destFull) { $skip++; continue }
            # 把父目录拖进它自己的子目录：跳过，否则无限嵌套
            if ($isDir -and -not $srcFull) { $skip++; continue }
            if ($isDir -and (($destFull + '\').StartsWith($srcFull + '\'))) { $skip++; continue }

            $target = Join-Path $destFull (Split-Path -Leaf $p)
            $target = Get-UniquePath -Target $target -IsDir $isDir

            if ($isDir) {
                Copy-Item -LiteralPath $p -Destination $target -Recurse -Force -ErrorAction Stop
            } else {
                Copy-Item -LiteralPath $p -Destination $target -Force -ErrorAction Stop
            }
            $ok++
        } catch {
            $fail++
            $lastErr = $_.Exception.Message
        }
    }

    if ($Quiet) { return }

    Refresh-CurrentView

    $msg = '已复制 ' + $ok + ' 项'
    if ($skip -gt 0) { $msg += '，跳过 ' + $skip + ' 项（已在当前目录）' }
    if ($fail -gt 0) { $msg += '，失败 ' + $fail + ' 项' }
    $script:lblStatus.Text = $msg

    if ($fail -gt 0) {
        [Windows.Forms.MessageBox]::Show(($msg + "`r`n`r`n最后一个错误：`r`n" + $lastErr), '桌面框', 'OK', 'Warning') | Out-Null
    }
}

function Copy-Selected {
    param($List)
    $paths = Get-SelectedPaths -List $List
    if ($paths.Count -eq 0) { $script:lblStatus.Text = '没有选中任何项目'; return }
    if (Set-ClipboardFiles $paths) {
        $script:lblStatus.Text = ('已复制 ' + $paths.Count + ' 项，可在别的文件夹里粘贴')
    } else {
        $script:lblStatus.Text = '复制到剪贴板失败'
    }
}

function Cut-Selected {
    param($List)
    $paths = Get-SelectedPaths -List $List
    if ($paths.Count -eq 0) { $script:lblStatus.Text = '没有选中任何项目'; return }
    if (Set-ClipboardFiles $paths -Move) {
        $script:lblStatus.Text = ('已剪切 ' + $paths.Count + ' 项，去目标文件夹按 Ctrl+V 就搬过去')
    } else {
        $script:lblStatus.Text = '剪切失败'
    }
}

function Paste-Clipboard {
    param([string]$Dest)
    if (-not $Dest) { $Dest = $script:CurrentPath }
    if (-not $Dest) {
        [Windows.Forms.MessageBox]::Show(('现在显示的是分区总览，粘到哪儿还没确定。' + "`r`n`r`n" + '先双击进入某个文件夹，再按 Ctrl+V。'), '桌面框', 'OK', 'Information') | Out-Null
        return
    }
    $files = Get-ClipboardFiles
    if ($files.Count -eq 0) { $script:lblStatus.Text = '剪贴板里没有文件或文件夹'; return }

    # 剪贴板里标了「剪切」就移动，否则照旧复制
    if ((Get-ClipboardDropEffect) -eq 2) {
        Move-PathsInto -Paths $files -Dest $Dest
    } else {
        Copy-PathsInto -Paths $files -Dest $Dest
    }
}

function Open-SelectedItem {
    param($Item, $List)
    $t = $null
    if ($Item) { $t = $Item.Tag }
    elseif ($List -and $List.SelectedItems.Count -gt 0) { $t = $List.SelectedItems[0].Tag }
    elseif ($script:lv.SelectedItems.Count -gt 0) { $t = $script:lv.SelectedItems[0].Tag }
    if (-not $t) { return }
    if ($t.IsDir) {
        Show-Folder -Path $t.Path
    } else {
        try { Start-Process -FilePath $t.Path }
        catch { [Windows.Forms.MessageBox]::Show(('无法打开：' + $t.Path), '桌面框', 'OK', 'Warning') | Out-Null }
    }
}

function Open-Source {
    # 标签栏取消后，这里统一回到「所有分区一屏列出」
    param($Source)
    $script:CurrentSource = $Source
    Show-AllSources
}

function Add-SourcePath {
    param([string]$Path)
    if (-not $Path) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    foreach ($s in $script:Sources) {
        if ($s.path -eq $Path) { Show-AllSources; return }
    }
    $name = Split-Path -Leaf $Path
    if (-not $name) { $name = $Path }
    $script:Sources += [pscustomobject]@{ name = $name; path = $Path }
    $script:AppCfg.sources = @($script:Sources)
    Save-Config $script:AppCfg | Out-Null
    Show-AllSources
}

function Rebuild-Tabs {
    # 分区视图取代了标签栏。保留空壳，避免散落的旧调用点报错。
    if ($script:pnlTabs) { $script:pnlTabs.Visible = $false }
    Update-Layout
}

function Toggle-Collapse {
    if ($script:Collapsed) {
        # 先改状态再改高度：设置 Height 会同步触发 Resize → Update-Layout，
        # 状态晚一步改的话，那一次布局会走错分支，把内容尺寸算在收起时的小盒子里。
        $script:Collapsed = $false
        $form.Height = $script:ExpandedHeight
        # 关键：展开时按「当前视图」还原，不能一律显示列表。
        # 以前这里写死 $script:lv.Visible = $true —— 在分区总览下收起再展开，
        # 那个（没进过文件夹、因此是空的）ListView 会被拉成整块大小盖在所有分区上面，
        # 表现就是「框回来了，里面一片空白，只剩一个『名称』表头」。
        # 判断视图用 CurrentPath 而不是读 .Visible：窗体没显示时 .Visible 恒为 False，靠不住。
        $inFolder = [bool]$script:CurrentPath
        $hasSrc = (@($script:Sources | Where-Object { $_.path }).Count -gt 0)
        if ($inFolder) {
            $script:lv.Visible = $true
            if ($script:pnlBody) { $script:pnlBody.Visible = $false }
        } elseif ($hasSrc) {
            $script:lv.Visible = $false
            if ($script:pnlBody) { $script:pnlBody.Visible = $true }
        } else {
            $script:lv.Visible = $false
            if ($script:pnlBody) { $script:pnlBody.Visible = $false }
        }
        $script:lblStatus.Visible = $true
        $script:btnCollapse.Text = '—'
    } else {
        $script:ExpandedHeight = $form.Height
        $script:Collapsed = $true
        $form.Height = 42
        $script:lv.Visible = $false
        $script:lblStatus.Visible = $false
        $script:btnCollapse.Text = '▣'
    }
    Update-Layout
}

$script:SetSaved = $false

# ---------------------------------------------------------------- 固定（只锁窗口位置）
function Set-Locked {
    param([bool]$On, [switch]$NoSave)

    $script:Locked = $On

    if ($script:btnLock) {
        if ($On) {
            # 亮起来表示「已经固定住了」，和旁边几个灰按钮区分开
            $script:btnLock.BackColor = $clrAccentSoft
            $script:btnLock.ForeColor = [Drawing.Color]::White
        } else {
            $script:btnLock.BackColor = $clrBg
            $script:btnLock.ForeColor = $clrMuted
        }
    }

    # 四边 / 四角那圈手柄照旧可用：固定只锁「位置」，窗口大小仍然要能拉。
    # 之前锁定时把它们藏掉，结果是「位置锁住了，连带大小也调不了」—— 这两件事该分开。
    if ($script:Edges) { foreach ($k in @($script:Edges.Keys)) { $script:Edges[$k].Visible = $true } }
    if ($script:Corners) { foreach ($k in @($script:Corners.Keys)) { $script:Corners[$k].Visible = $true } }

    # 分区之间那条 6px 横条不跟「固定」联动：固定只管窗口位置，各分区高度随时能拖。
    if ($On -and $script:ResizeBlock) { $script:ResizeBlock = $null }   # 拖动途中被锁，收掉半截状态

    if (-not $NoSave) {
        try {
            $script:AppCfg.window.locked = $On
            Save-Config $script:AppCfg | Out-Null
        } catch { }
    }
}

# ---------------------------------------------------------------- 开机自动启动
# 写当前用户的 HKCU\Software\Microsoft\Windows\CurrentVersion\Run，不改系统级 HKLM，
# 不需要管理员权限。命令用「启动桌面框.vbs」——和用户自己双击的那条路完全一样，
# 它会用 -WindowStyle Hidden 拉起 powershell，登录时不会先闪一个黑框。
$script:RunKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunValueName = 'DesktopBox'

function Get-AutoStartCommand {
    $base = Split-Path -Parent $script:Root        # app 的上一级，也就是启动脚本所在目录
    $vbs = Join-Path $base '启动桌面框.vbs'
    if (Test-Path -LiteralPath $vbs) { return ('wscript.exe "' + $vbs + '"') }
    # 没有 vbs 就退回直接拉 ps1（有些用户会把 vbs 挪走）
    $ps1 = Join-Path $script:Root 'desktop_box.ps1'
    return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ps1 + '"')
}

function Get-AutoStartValue {
    param([string]$Name = $script:RunValueName)
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunKeyPath, $false)
        if (-not $k) { return $null }
        try { return [string]$k.GetValue($Name, $null) } finally { $k.Close() }
    } catch { return $null }
}

function Test-AutoStart {
    param([string]$Name = $script:RunValueName)
    $v = Get-AutoStartValue -Name $Name
    return [bool]$v
}

function Set-AutoStart {
    param([bool]$On, [string]$Name = $script:RunValueName)
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:RunKeyPath, $true)
        if (-not $k) { $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:RunKeyPath) }
        if (-not $k) { return $false }
        try {
            if ($On) {
                $k.SetValue($Name, (Get-AutoStartCommand), [Microsoft.Win32.RegistryValueKind]::String)
            } else {
                try { $k.DeleteValue($Name, $false) } catch { }
            }
        } finally { $k.Close() }
        return $true
    } catch { return $false }
}

function Repair-AutoStart {
    # 整个文件夹被搬走 / 改名后，注册表里那条老路径就失效了。
    # 只在「已经开着自启」时顺手改成当前路径，没开就什么都不做。
    $cur = Get-AutoStartValue
    if (-not $cur) { return }
    $want = Get-AutoStartCommand
    if ($cur -ne $want) { Set-AutoStart -On $true | Out-Null }
}

function Update-SettingList {
    if (-not $script:SetList) { return }
    try {
        $script:SetList.Items.Clear()
        foreach ($s in $script:Sources) {
            [void]$script:SetList.Items.Add($s.name + '   →   ' + $s.path)
        }
    } catch { }
}

function Show-Settings {
    if ($script:SetDlg -and -not $script:SetDlg.IsDisposed) {
        try { $script:SetDlg.Activate() } catch { }
        return
    }

    # 注意：事件处理器里的对象一律用 $script: 变量引用。
    # PowerShell 是动态作用域，函数返回后局部变量就没了，
    # 事件里再读 $dlg / $lb 会拿到 $null，按钮就完全没反应。
    $dlg = New-Object Windows.Forms.Form
    $script:SetDlg = $dlg
    $script:SetSaved = $false
    $dlg.Text = '设置'
    $dlg.ClientSize = New-Object Drawing.Size(524, 444)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $clrBg
    $dlg.Font = $fontBody
    $dlg.TopMost = $true

    $tip = New-Object Windows.Forms.Label
    $tip.Text = '每一个「来源」就是框顶部可以切换的一个文件夹。'
    $tip.SetBounds(16, 12, 490, 22)
    $tip.ForeColor = $clrMuted
    $dlg.Controls.Add($tip)

    $lb = New-Object Windows.Forms.ListBox
    $script:SetList = $lb
    $lb.SetBounds(16, 40, 492, 190)
    $lb.Font = $fontBody
    $lb.BorderStyle = 'FixedSingle'
    $dlg.Controls.Add($lb)

    $lblOp = New-Object Windows.Forms.Label
    $lblOp.Text = '背景不透明度'
    $lblOp.SetBounds(16, 246, 110, 24)
    $lblOp.ForeColor = $clrFg
    $dlg.Controls.Add($lblOp)

    $tbOp = New-Object Windows.Forms.TrackBar
    $script:SetOpacity = $tbOp
    $tbOp.SetBounds(130, 240, 290, 36)
    $tbOp.Minimum = 40
    $tbOp.Maximum = 100
    $tbOp.TickFrequency = 10
    $tbOp.SmallChange = 1
    $tbOp.LargeChange = 5
    $cur = 97
    try { $cur = [int]([double]$script:AppCfg.window.opacity * 100) } catch { }
    if ($cur -lt 40) { $cur = 40 }
    if ($cur -gt 100) { $cur = 100 }
    $tbOp.Value = $cur
    $dlg.Controls.Add($tbOp)

    $lblOpVal = New-Object Windows.Forms.Label
    $script:SetOpacityLabel = $lblOpVal
    $lblOpVal.Text = ($cur.ToString() + '%')
    $lblOpVal.SetBounds(424, 246, 70, 24)
    $lblOpVal.ForeColor = $clrAccent
    $dlg.Controls.Add($lblOpVal)

    $tbOp.Add_ValueChanged({
        $v = $this.Value
        try { $form.Opacity = [double]$v / 100.0 } catch { }
        if ($script:SetOpacityLabel) { $script:SetOpacityLabel.Text = ($v.ToString() + '%') }
    })

    # 开机自动启动：勾上 = 登录 Windows 后自动拉起，启动时按 config.json 恢复
    # 上次关闭前的样子（位置、大小、透明度、分区列表、固定状态都在里面）。
    # 只动当前用户的 Run 键，不需要管理员权限。
    $chkAuto = New-Object Windows.Forms.CheckBox
    $script:SetAutoStart = $chkAuto
    $chkAuto.Text = '开机自动启动（恢复上次关闭时的状态）'
    $chkAuto.SetBounds(16, 292, 380, 24)
    $chkAuto.ForeColor = $clrFg
    $chkAuto.BackColor = $clrBg
    $chkAuto.Checked = (Test-AutoStart)
    $dlg.Controls.Add($chkAuto)

    $btnAddDir = New-Object Windows.Forms.Button
    $btnAddDir.Text = '添加目录'
    $btnAddDir.SetBounds(16, 344, 104, 32)
    $btnAddDir.Add_Click({
        $fb = New-Object Windows.Forms.FolderBrowserDialog
        $fb.Description = '选择要放进桌面框的文件夹'
        $fb.ShowNewFolderButton = $false
        if ($fb.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) {
            $p = $fb.SelectedPath
            if ($p) {
                $script:Sources += [pscustomobject]@{ name = (Split-Path -Leaf $p); path = $p }
                Update-SettingList
            }
        }
    })
    $dlg.Controls.Add($btnAddDir)

    $btnDel = New-Object Windows.Forms.Button
    $btnDel.Text = '移除选中'
    $btnDel.SetBounds(128, 344, 104, 32)
    $btnDel.Add_Click({
        if (-not $script:SetList) { return }
        $idx = $script:SetList.SelectedIndex
        if ($idx -lt 0) { return }
        $tmp = @()
        for ($i = 0; $i -lt $script:Sources.Count; $i++) {
            if ($i -ne $idx) { $tmp += $script:Sources[$i] }
        }
        $script:Sources = $tmp
        Update-SettingList
    })
    $dlg.Controls.Add($btnDel)

    $btnCfgFile = New-Object Windows.Forms.Button
    $btnCfgFile.Text = '打开配置文件'
    $btnCfgFile.SetBounds(240, 344, 104, 32)
    $btnCfgFile.Add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList $script:ConfigPath })
    $dlg.Controls.Add($btnCfgFile)

    $btnOk = New-Object Windows.Forms.Button
    $btnOk.Text = '保存并关闭'
    $btnOk.SetBounds(392, 344, 116, 32)
    $btnOk.Add_Click({
        $script:AppCfg.sources = @($script:Sources)
        if ($script:SetOpacity) {
            $op = [double]$script:SetOpacity.Value / 100.0
            if ($op -ge 0.4 -and $op -le 1) { $script:AppCfg.window.opacity = $op }
        }
        # 开机自启真实状态就在注册表里，勾选与否以复选框为准写回去
        if ($script:SetAutoStart) {
            try { Set-AutoStart -On ([bool]$script:SetAutoStart.Checked) | Out-Null } catch { }
        }
        Save-Config $script:AppCfg | Out-Null
        $script:SetSaved = $true
        if ($script:SetDlg) { $script:SetDlg.Close() }
    })
    $dlg.Controls.Add($btnOk)

    $hint = New-Object Windows.Forms.Label
    $hint.Text = '不透明度越低越能透出后面的桌面，但文字也会跟着变淡。60%～85% 通常最舒服。'
    $hint.SetBounds(16, 388, 492, 44)
    $hint.ForeColor = $clrMuted
    $dlg.Controls.Add($hint)

    Update-SettingList
    [void]$dlg.ShowDialog($form)

    # 没点保存就关掉：把透明度退回原值，别留下半截效果
    if (-not $script:SetSaved) {
        try { $form.Opacity = [double]$script:AppCfg.window.opacity } catch { }
    }

    $script:SetDlg = $null
    $script:SetList = $null
    $script:SetOpacity = $null
    $script:SetOpacityLabel = $null
    $script:SetAutoStart = $null

    $script:AppCfg.sources = @($script:Sources)
    if ($script:Sources.Count -gt 0) {
        $script:pnlEmpty.Visible = $false
        $script:lv.Visible = $true
        Show-AllSources
    } else {
        $script:pnlEmpty.Visible = $true
        $script:lv.Visible = $false
        $script:lblStatus.Text = '等待添加目录'
        Update-Layout
    }
}

# ---------------------------------------------------------------- 窗口
$form = New-Object Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.Text = $script:AppCfg.title
$form.BackColor = $clrBg
# MinimumSize 会被用于所有 SetBounds，包括程序自己设置的高度，
# 所以高度下限必须放到「收起成一条」的高度，否则点 — 收不下去（以前写 280，实际最多收 280）。
# 顶部路径条去掉后，收起高度从 62 降到 42（标题行 1..39，底下不留空档）。
# 用户拖拽时的 200 下限在 ResizeMove 里单独卡，不受这里影响。
$form.MinimumSize = New-Object Drawing.Size(420, 42)
$form.Size = New-Object Drawing.Size([int]$script:AppCfg.window.width, [int]$script:AppCfg.window.height)
$form.Location = New-Object Drawing.Point([int]$script:AppCfg.window.x, [int]$script:AppCfg.window.y)
$form.TopMost = [bool]$script:AppCfg.window.topmost
$form.Opacity = [double]$script:AppCfg.window.opacity
# 不在任务栏占一格：任务栏那个图标是宿主 powershell.exe 的，蓝底白箭头，很扎眼。
# 框本身就贴在桌面上，要显示/隐藏用托盘图标双击即可，不损失任何操作。
$form.ShowInTaskbar = $false

# 位置纠偏：配置里记录的位置若落在所有屏幕之外（换过显示器 / 拔过扩展屏），
# 窗口会出现在看不见的地方。这里检测不到任何交集就拉回主屏居中。
try {
    $proposed = New-Object Drawing.Rectangle($form.Location.X, $form.Location.Y, $form.Width, $form.Height)
    $visible = $false
    foreach ($sc in [Windows.Forms.Screen]::AllScreens) {
        $hit = [Drawing.Rectangle]::Intersect($proposed, $sc.WorkingArea)
        if ($hit.Width -gt 80 -and $hit.Height -gt 60) { $visible = $true; break }
    }
    if (-not $visible) {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $nx = $wa.X + [int](($wa.Width - $form.Width) / 2)
        $ny = $wa.Y + [int](($wa.Height - $form.Height) / 2)
        if ($nx -lt $wa.X) { $nx = $wa.X + 40 }
        if ($ny -lt $wa.Y) { $ny = $wa.Y + 40 }
        $form.Location = New-Object Drawing.Point($nx, $ny)
    }
} catch { }

$script:pnlTitle = New-Object Windows.Forms.Panel
$script:pnlTitle.BackColor = $clrBg
$form.Controls.Add($script:pnlTitle)

$script:lblTitle = New-Object Windows.Forms.Label
$script:lblTitle.Text = $script:AppCfg.title
$script:lblTitle.Font = $fontTitle
$script:lblTitle.ForeColor = $clrFg
$script:lblTitle.BackColor = $clrBg
$script:lblTitle.TextAlign = 'MiddleLeft'
$script:lblTitle.AutoSize = $false
$script:pnlTitle.Controls.Add($script:lblTitle)

$script:btnBack = New-Object Windows.Forms.Label
$script:btnBack.Text = '‹'
$script:btnBack.Font = $fontIcon
$script:btnBack.TextAlign = 'MiddleCenter'
$script:btnBack.Size = New-Object Drawing.Size(24, 24)
$script:btnBack.Cursor = 'Hand'
$script:btnBack.BackColor = $clrBg
$script:btnBack.ForeColor = $clrLine
$script:btnBack.Add_Click({
    if ($script:History.Count -gt 0) {
        $p = $script:History.Pop()
        if ($p) { Show-Folder -Path $p -NoHistory } else { Show-AllSources }
    }
})
$script:btnBack.Add_MouseEnter({ if ($script:History.Count -gt 0) { $this.BackColor = $clrHover } })
$script:btnBack.Add_MouseLeave({ $this.BackColor = $clrBg })
$script:pnlTitle.Controls.Add($script:btnBack)

$script:btnSettings = New-Object Windows.Forms.Label
$script:btnSettings.Text = '⚙'
$script:btnSettings.Font = $fontIcon
$script:btnSettings.TextAlign = 'MiddleCenter'
$script:btnSettings.Size = New-Object Drawing.Size(30, 24)
$script:btnSettings.Cursor = 'Hand'
$script:btnSettings.BackColor = $clrBg
$script:btnSettings.ForeColor = $clrMuted
$script:btnSettings.Add_Click({ Show-Settings })
$script:btnSettings.Add_MouseEnter({ $this.BackColor = $clrHover })
$script:btnSettings.Add_MouseLeave({ $this.BackColor = $clrBg })
$script:pnlTitle.Controls.Add($script:btnSettings)

# 固定：只锁住窗口的位置，防止手滑把框拖歪。
# 拉边改大小、拖分区之间那条横条改高度、翻目录、折叠分区、拖文件出去，全都照旧。
$script:btnLock = New-Object Windows.Forms.Label
$script:btnLock.Text = '固'
$script:btnLock.Font = $fontBody
$script:btnLock.TextAlign = 'MiddleCenter'
$script:btnLock.Size = New-Object Drawing.Size(30, 24)
$script:btnLock.Cursor = 'Hand'
$script:btnLock.BackColor = $clrBg
$script:btnLock.ForeColor = $clrMuted
$script:btnLock.Add_Click({ Set-Locked (-not $script:Locked) })
$script:btnLock.Add_MouseEnter({ if (-not $script:Locked) { $this.BackColor = $clrHover } })
$script:btnLock.Add_MouseLeave({ if (-not $script:Locked) { $this.BackColor = $clrBg } })
$script:pnlTitle.Controls.Add($script:btnLock)

$script:btnRefresh = New-Object Windows.Forms.Label
$script:btnRefresh.Text = '⟳'
$script:btnRefresh.Font = $fontIcon
$script:btnRefresh.TextAlign = 'MiddleCenter'
$script:btnRefresh.Size = New-Object Drawing.Size(30, 24)
$script:btnRefresh.Cursor = 'Hand'
$script:btnRefresh.BackColor = $clrBg
$script:btnRefresh.ForeColor = $clrMuted
$script:btnRefresh.Add_Click({ if ($script:CurrentPath) { Show-Folder -Path $script:CurrentPath -NoHistory } else { Show-AllSources } })
$script:btnRefresh.Add_MouseEnter({ $this.BackColor = $clrHover })
$script:btnRefresh.Add_MouseLeave({ $this.BackColor = $clrBg })
$script:pnlTitle.Controls.Add($script:btnRefresh)

$script:btnCollapse = New-Object Windows.Forms.Label
$script:btnCollapse.Text = '—'
$script:btnCollapse.Font = $fontBody
$script:btnCollapse.TextAlign = 'MiddleCenter'
$script:btnCollapse.Size = New-Object Drawing.Size(30, 24)
$script:btnCollapse.Cursor = 'Hand'
$script:btnCollapse.BackColor = $clrBg
$script:btnCollapse.ForeColor = $clrMuted
$script:btnCollapse.Add_Click({ Toggle-Collapse })
$script:btnCollapse.Add_MouseEnter({ $this.BackColor = $clrHover })
$script:btnCollapse.Add_MouseLeave({ $this.BackColor = $clrBg })
$script:pnlTitle.Controls.Add($script:btnCollapse)

$script:btnClose = New-Object Windows.Forms.Label
$script:btnClose.Text = '×'
$script:btnClose.Font = $fontBody
$script:btnClose.TextAlign = 'MiddleCenter'
$script:btnClose.Size = New-Object Drawing.Size(30, 24)
$script:btnClose.Cursor = 'Hand'
$script:btnClose.BackColor = $clrBg
$script:btnClose.ForeColor = $clrMuted
$script:btnClose.Add_Click({ $form.Close() })
$script:btnClose.Add_MouseEnter({ $this.BackColor = [Drawing.ColorTranslator]::FromHtml('#F2DCD8'); $this.ForeColor = [Drawing.ColorTranslator]::FromHtml('#B23B2E') })
$script:btnClose.Add_MouseLeave({ $this.BackColor = $clrBg; $this.ForeColor = $clrMuted })
$script:pnlTitle.Controls.Add($script:btnClose)

$script:pnlTabs = New-Object Windows.Forms.Panel
$script:pnlTabs.BackColor = $clrBg
$script:pnlTabs.Visible = $false
$form.Controls.Add($script:pnlTabs)

# 所有列表共用同一份小图标缓存
$script:imgSmall = New-Object Windows.Forms.ImageList
$script:imgSmall.ImageSize = New-Object Drawing.Size(16, 26)
$script:imgSmall.ColorDepth = [Windows.Forms.ColorDepth]::Depth32Bit
# 先塞一张占位图：ImageList 非空时行高才会按 ImageSize 撑开
$script:imgSmall.Images.Add('.blank', (New-Object Drawing.Bitmap 16, 16))
# Details 视图里实际行高 = 图标高度 + 上下留白 4px，算分区自适应高度要用它
$script:RowH = 26 + 4

# 单目录视图用的大列表
$script:lv = New-Object Windows.Forms.ListView
$script:lv.View = 'Details'
$script:lv.BorderStyle = 'None'
$script:lv.BackColor = $clrBg
$script:lv.ForeColor = $clrFg
$script:lv.Font = $fontBody
$script:lv.MultiSelect = $true
$script:lv.HideSelection = $false
$script:lv.FullRowSelect = $true
$script:lv.GridLines = $false
$script:lv.HeaderStyle = 'Clickable'
$script:lv.ShowItemToolTips = $true
$script:lv.SmallImageList = $script:imgSmall
$script:lv.AllowDrop = $true
[void]$script:lv.Columns.Add('名称', 600, 'Left')
$form.Controls.Add($script:lv)

# 分区容器：高度可滚，里面每个分区各自一个小区块
$script:pnlBody = New-Object Windows.Forms.Panel
$script:pnlBody.BackColor = $clrBg
$script:pnlBody.AutoScroll = $true
$script:pnlBody.Visible = $false
$form.Controls.Add($script:pnlBody)

# 点「名称」表头切换升降序（分区视图和单目录视图都适用）
$script:lv.Add_ColumnClick({
    param($cSender, $cArgs)
    $script:SortAsc = -not $script:SortAsc
    Refresh-CurrentView
})
$script:lv.Add_Resize({ Fit-Columns })

$script:lblStatus = New-Object Windows.Forms.Label
$script:lblStatus.AutoSize = $false
$script:lblStatus.TextAlign = 'MiddleLeft'
$script:lblStatus.Font = $fontSmall
$script:lblStatus.ForeColor = $clrMuted
$script:lblStatus.BackColor = $clrBg
$script:lblStatus.Padding = New-Object Windows.Forms.Padding(12, 0, 12, 0)
$script:lblStatus.Text = '就绪'
$form.Controls.Add($script:lblStatus)

$script:pnlEmpty = New-Object Windows.Forms.Panel
$script:pnlEmpty.BackColor = $clrBg
$script:pnlEmpty.Visible = $false
$form.Controls.Add($script:pnlEmpty)
$script:pnlEmpty.BringToFront()

$script:lblEmpty1 = New-Object Windows.Forms.Label
$script:lblEmpty1.Text = '框中还没有目录'
$script:lblEmpty1.Font = $fontTitle
$script:lblEmpty1.ForeColor = $clrFg
$script:lblEmpty1.TextAlign = 'MiddleCenter'
$script:lblEmpty1.BackColor = $clrBg
$script:pnlEmpty.Controls.Add($script:lblEmpty1)

$script:lblEmpty2 = New-Object Windows.Forms.Label
$script:lblEmpty2.Text = '选择 D / E / F 盘里的文件夹，文件仍留在原盘，不占 C 盘空间'
$script:lblEmpty2.Font = $fontSmall
$script:lblEmpty2.ForeColor = $clrMuted
$script:lblEmpty2.TextAlign = 'MiddleCenter'
$script:lblEmpty2.BackColor = $clrBg
$script:pnlEmpty.Controls.Add($script:lblEmpty2)

$script:btnAdd = New-Object Windows.Forms.Label
$script:btnAdd.Text = '＋ 添加目录'
$script:btnAdd.Font = $fontBody
$script:btnAdd.TextAlign = 'MiddleCenter'
$script:btnAdd.Size = New-Object Drawing.Size(140, 34)
$script:btnAdd.Cursor = 'Hand'
$script:btnAdd.BackColor = $clrAccent
$script:btnAdd.ForeColor = [Drawing.Color]::White
$script:btnAdd.Add_Click({ Show-Settings })
$script:pnlEmpty.Controls.Add($script:btnAdd)

$script:btnCfg = New-Object Windows.Forms.Label
$script:btnCfg.Text = '打开配置文件'
$script:btnCfg.Font = $fontSmall
$script:btnCfg.TextAlign = 'MiddleCenter'
$script:btnCfg.Size = New-Object Drawing.Size(140, 30)
$script:btnCfg.Cursor = 'Hand'
$script:btnCfg.BackColor = $clrSoft
$script:btnCfg.ForeColor = $clrMuted
$script:btnCfg.Add_Click({ Start-Process -FilePath 'notepad.exe' -ArgumentList $script:ConfigPath })
$script:pnlEmpty.Controls.Add($script:btnCfg)

# ------------------------------------------------------ 拖动 / 缩放 / 事件
$startDrag = {
    # 固定状态下整窗拖不动（位置锁死）。注意：拉边改大小**不**走这里，
    # 上面那条 ResizeZone 已经不拦锁定了，所以固定时窗口大小照样能调。
    if ($script:Locked) { return }
    $script:Dragging = $true
    $script:DragX = [Windows.Forms.Cursor]::Position.X - $form.Left
    $script:DragY = [Windows.Forms.Cursor]::Position.Y - $form.Top
}
$doDrag = {
    if ($script:Dragging) {
        $form.Left = [Windows.Forms.Cursor]::Position.X - $script:DragX
        $form.Top = [Windows.Forms.Cursor]::Position.Y - $script:DragY
    }
}
$endDrag = { $script:Dragging = $false }

foreach ($c in @($script:pnlTitle, $script:lblTitle)) {
    $c.Add_MouseDown($startDrag)
    $c.Add_MouseMove($doDrag)
    $c.Add_MouseUp($endDrag)
}
$script:pnlTabs.Add_MouseDown($startDrag)
$script:pnlTabs.Add_MouseMove($doDrag)
$script:pnlTabs.Add_MouseUp($endDrag)

# ------------------------------------------------------ 八向调大小
# 窗口是无边框的（FormBorderStyle = None），系统自带的边缘拖拽随之消失，
# 所以自己沿四条边、四个角铺一圈「隐形边框」：透明小板 + 对应方向的鼠标指针。
$script:EdgeT = 5      # 边的响应宽度
$script:CornerT = 16   # 角的响应方块边长
$script:MinWinW = 420  # 拖拽时的最小宽
$script:MinWinH = 200  # 拖拽时的最小高（收起到 62 是程序行为，不走这里）
$script:EdgeZone = $null

$script:ResizeZone = {
    param($zone)

    # 固定状态不拦这一条：固定只锁位置，拉边改大小照样允许
    $script:EdgeZone = $zone
    $script:EdgeX = [Windows.Forms.Cursor]::Position.X
    $script:EdgeY = [Windows.Forms.Cursor]::Position.Y
    $script:EdgeRect = $form.Bounds
}

$script:ResizeMove = {
    # $TestDx/$TestDy 只给自检用：真实运行时按鼠标位置算位移，
    # 但自检里光标随时可能在动，用固定位移才能得到确定的期望值。
    param($TestDx, $TestDy)

    if (-not $script:EdgeZone) { return }

    if ($null -ne $TestDx) { $dx = [double]$TestDx } else { $dx = [Windows.Forms.Cursor]::Position.X - $script:EdgeX }
    if ($null -ne $TestDy) { $dy = [double]$TestDy } else { $dy = [Windows.Forms.Cursor]::Position.Y - $script:EdgeY }
    $z = $script:EdgeZone
    $r = $script:EdgeRect

    $minW = [Math]::Max($script:MinWinW, $form.MinimumSize.Width)
    $minH = $script:MinWinH

    $x = $r.X; $y = $r.Y; $w = $r.Width; $h = $r.Height

    if ($z -match 'E') { $w = [Math]::Max($minW, $r.Width + $dx) }
    if ($z -match 'W') {
        $w = [Math]::Max($minW, $r.Width - $dx)
        $x = $r.Right - $w
    }
    if ($z -match '^S') { $h = [Math]::Max($minH, $r.Height + $dy) }
    if ($z -match '^N') {
        $h = [Math]::Max($minH, $r.Height - $dy)
        $y = $r.Bottom - $h
    }

    $form.SetBounds($x, $y, $w, $h)
}

$script:ResizeEnd = {
    if (-not $script:EdgeZone) { return }
    $script:EdgeZone = $null
    Update-Layout
    # 尺寸立刻落盘，别等关闭时才写（托盘退出、强制结束都不会触发 FormClosing）
    try {
        $script:AppCfg.window.x = $form.Left
        $script:AppCfg.window.y = $form.Top
        $script:AppCfg.window.width = $form.Width
        $script:AppCfg.window.height = if ($script:Collapsed) { $script:ExpandedHeight } else { $form.Height }
        Save-Config $script:AppCfg | Out-Null
    } catch { }
}

function New-ResizeHandle {
    param([string]$Zone)

    $p = New-Object Windows.Forms.Panel
    $p.BackColor = $clrBg
    $p.Tag = $Zone

    switch ($Zone) {
        'N' { $p.Cursor = [Windows.Forms.Cursors]::SizeNS }
        'S' { $p.Cursor = [Windows.Forms.Cursors]::SizeNS }
        'E' { $p.Cursor = [Windows.Forms.Cursors]::SizeWE }
        'W' { $p.Cursor = [Windows.Forms.Cursors]::SizeWE }
        'NE' { $p.Cursor = [Windows.Forms.Cursors]::SizeNESW }
        'SW' { $p.Cursor = [Windows.Forms.Cursors]::SizeNESW }
        'NW' { $p.Cursor = [Windows.Forms.Cursors]::SizeNWSE }
        default { $p.Cursor = [Windows.Forms.Cursors]::SizeNWSE }
    }

    $p.Add_MouseDown({
        $this.Capture = $true
        & $script:ResizeZone ([string]$this.Tag)
    })
    $p.Add_MouseMove({ & $script:ResizeMove })
    $p.Add_MouseUp({
        $this.Capture = $false
        & $script:ResizeEnd
    })

    $form.Controls.Add($p)
    return $p
}

# 先铺四条边，再铺四个角；角最后 BringToFront，确保角上的响应优先
$script:Edges = @{}
foreach ($z in @('N', 'S', 'E', 'W')) { $script:Edges[$z] = New-ResizeHandle -Zone $z }
$script:Corners = @{}
foreach ($z in @('NW', 'NE', 'SW', 'SE')) { $script:Corners[$z] = New-ResizeHandle -Zone $z }
foreach ($z in @('N', 'S', 'E', 'W')) { $script:Edges[$z].BringToFront() }
foreach ($z in @('NW', 'NE', 'SW', 'SE')) { $script:Corners[$z].BringToFront() }

# 上次退出时是「固定」状态的话，这次启动接着锁着（不写盘，配置本来就是对的）
if ($script:Locked) { Set-Locked $true -NoSave }

# 开着开机自启的话，顺手核对一下注册表那条还指得着现在这个目录
# （整个文件夹被搬走/改名后老路径就失效了）。自检 / 测试模式不碰用户注册表。
if (-not $SelfCheck -and -not $Test) { try { Repair-AutoStart } catch { } }

function Place-ResizeHandles {
    $w = $form.ClientSize.Width
    $h = $form.ClientSize.Height
    $t = $script:EdgeT
    $c = $script:CornerT
    if ($w -lt 60 -or $h -lt 40) { return }

    $script:Edges['N'].SetBounds(0, 0, $w, $t)
    $script:Edges['S'].SetBounds(0, $h - $t, $w, $t)
    $script:Edges['E'].SetBounds($w - $t, 0, $t, $h)
    $script:Edges['W'].SetBounds(0, 0, $t, $h)

    $script:Corners['NW'].SetBounds(0, 0, $c, $c)
    $script:Corners['NE'].SetBounds($w - $c, 0, $c, $c)
    $script:Corners['SW'].SetBounds(0, $h - $c, $c, $c)
    $script:Corners['SE'].SetBounds($w - $c, $h - $c, $c, $c)
}

# ------------------------------------------------------ 列表通用事件
# 单目录视图和每个分区的小列表共用同一套处理器

# 鼠标滚轮：列表滚到头之后，把这一格滚轮交给外层的分区容器。
# 不这么接的话，滚轮落在文件行上完全没反应 —— ListView 会把 WM_MOUSEWHEEL 收下，
# 滚到自己的边界就停住，消息也不会往父容器传。
#
# 注意判据是「这个方向上还能不能滚」，不是「装不装得下」。
# 一开始写成「装得下才转交」，结果分区按内容自适应高度，往往恰好留一两行余量，
# ListView 永远「装不下」→ 一直在滚自己、外层一次都轮不到，
# 用户看到的就是「滚了跟没滚一样」。
#
# 算目标位置单独做成函数：窗体没显示时 AutoScrollPosition 赋值不生效，
# 端到端断言不了，只能把这段纯计算拿出来单独测。
function Get-WheelScrollTarget {
    param($List, $Body, [int]$Delta)

    if (-not $Body) { return $null }

    $maxY = [Math]::Max(0, $Body.AutoScrollMinSize.Height - $Body.ClientSize.Height)
    if ($maxY -le 0) { return $null }

    if ($List) {
        $rows = [Math]::Max(1, [int](($List.ClientSize.Height - 24) / $script:RowH))
        $top = 0
        $cnt = 0
        try { if ($List.TopItem) { $top = [int]$List.TopItem.Index } } catch { }
        try { $cnt = [int]$List.Items.Count } catch { }

        # 往下滚：下面还有没露出来的行，就让它自己滚
        if ($Delta -lt 0 -and ($top + $rows) -lt $cnt) { return $null }
        # 往上滚：上面还有没露出来的行，同理
        if ($Delta -gt 0 -and $top -gt 0) { return $null }
    }

    $cur = [Math]::Abs($Body.AutoScrollPosition.Y)
    $notches = [int]($Delta / 120)
    if ($notches -eq 0) { $notches = $(if ($Delta -gt 0) { 1 } else { -1 }) }

    $t = $cur - $notches * ($script:RowH * 2)
    if ($t -lt 0) { $t = 0 }
    if ($t -gt $maxY) { $t = $maxY }
    return $t
}

# 列表自己该不该吞掉这格滚轮，不再靠「容器高 ÷ 行高」估可见行数：
# 估多了就误判成「还能滚」，把滚轮吃掉却纹丝不动。改成把消息原样投给列表、
# 再看 GetScrollInfo 的 nPos 有没有变 —— 变没变是事实，不是估算。

$script:WheelToList = {
    param($wheelSender, $wheelArgs)

    $body = $script:pnlBody
    if (-not $body) { return }

    $target = Get-WheelScrollTarget -List $wheelSender -Body $body -Delta $wheelArgs.Delta
    if ($null -eq $target) { return }
    if ($target -eq [Math]::Abs($body.AutoScrollPosition.Y)) { return }

    # 接管了就别让列表再滚一遍，否则一格滚轮会跳两下
    try {
        if ($wheelArgs -is [Windows.Forms.HandledMouseEventArgs]) { $wheelArgs.Handled = $true }
    } catch { }

    try { $body.AutoScrollPosition = New-Object Drawing.Point(0, $target) } catch { }
}

# ------------------------------------------------------ 滚轮统一路由
# 只给 ListView 挂 MouseWheel 不够稳：滚轮消息究竟投给「焦点窗口」还是「光标下的窗口」，
# 取决于系统的「滚动非活动窗口」设置；ListView 在自己的 WndProc 里也可能把消息吃掉，
# 既不滚、也不触发鼠标事件。实测出现过「光标分明停在列表上、滚五格毫无反应」。
# 所以在消息泵这一层统一拦：光标下是哪个列表、这个方向还能不能滚，全在这里判断；
# 要接管就把消息吞掉，避免一次滚轮跳两下。
$wheelCode = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class WheelRouter : IMessageFilter
{
    public static Func<IntPtr, int, bool> Handler;

    [StructLayout(LayoutKind.Sequential)]
    struct SCROLLINFO
    {
        public uint cbSize;
        public uint fMask;
        public int nMin;
        public int nMax;
        public uint nPage;
        public int nPos;
        public int nTrackPos;
    }

    [DllImport("user32.dll")]
    static extern bool GetScrollInfo(IntPtr hWnd, int nBar, ref SCROLLINFO si);

    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

    // 返回 {nMin, nMax, nPos}；控件根本没有竖向滚动条时返回 null
    public static int[] Vert(IntPtr hWnd)
    {
        SCROLLINFO si = new SCROLLINFO();
        si.cbSize = (uint)Marshal.SizeOf(typeof(SCROLLINFO));
        si.fMask = 0x17;                       // SIF_RANGE | SIF_PAGE | SIF_POS | SIF_TRACKPOS
        if (!GetScrollInfo(hWnd, 1, ref si)) return null;   // SB_VERT
        return new int[] { si.nMin, si.nMax, si.nPos };
    }

    // 把一格滚轮原样投给指定的列表，让它用自己的 WndProc 滚
    public static void Poke(IntPtr hWnd, int delta, int screenX, int screenY)
    {
        // 全程用 uint 拼，别用 (long) 再移位 —— 符号扩展会触发 C# 警告，
        // 而 PowerShell 的 Add-Type 把警告当错误，整个类型都编译不出来。
        uint w = ((uint)(ushort)delta) << 16;
        uint l = (((uint)(ushort)screenY) << 16) | (ushort)screenX;
        SendMessage(hWnd, 0x020A, (IntPtr)w, (IntPtr)l);   // WM_MOUSEWHEEL
    }

    public bool PreFilterMessage(ref Message m)
    {
        if (m.Msg != 0x020A) return false;      // WM_MOUSEWHEEL
        if (Handler == null) return false;
        int delta = (short)(((long)m.WParam >> 16) & 0xFFFF);
        return Handler(m.HWnd, delta);
    }
}
'@

$script:WheelHook = {
    param([IntPtr]$hWnd, [int]$delta)

    $body = $script:pnlBody
    if (-not $body -or -not $body.Visible) { return $false }

    # 消息得是我们自己窗口的（弹出菜单、托盘之类的滚轮别掺和）
    $c = [Windows.Forms.Control]::FromHandle($hWnd)
    if (-not $c) { return $false }
    $root = $c
    $guard = 0
    while ($root.Parent -and $guard -lt 12) { $root = $root.Parent; $guard++ }
    if ($root -ne $form) { return $false }

    # 光标底下的那个列表（分区列表或单目录列表）
    $pt = [Windows.Forms.Cursor]::Position
    $list = $null
    foreach ($b in $script:Blocks) {
        if ($b.List -and $b.List.Visible -and $b.List.RectangleToScreen($b.List.ClientRectangle).Contains($pt)) {
            $list = $b.List
            break
        }
    }
    if (-not $list -and $script:lv -and $script:lv.Visible -and
        $script:lv.RectangleToScreen($script:lv.ClientRectangle).Contains($pt)) {
        $list = $script:lv
    }

    # 一、光标在列表上：直接把这一格滚轮投给它，让它按自己的 WndProc 滚。
    # 为什么不让消息自己走到列表上 —— 滚轮消息投的是「焦点窗口」（这里是窗体），
    # 窗体不会转给光标下的子控件，那个列表于是看起来"焊死"了一样。
    # 也不自己算行数去设 TopItem：可见行数一估错就变成「吃掉了却不动作」。
    # 这里只认两件事 —— 有没有滚动条（Vert 返回 null 即没有），滚完位置有没有变。
    $bodyBefore = [Math]::Abs($body.AutoScrollPosition.Y)
    if ($list) {
        $si0 = [WheelRouter]::Vert($list.Handle)
        $pos0 = $(if ($null -eq $si0) { -1 } else { $si0[2] })

        try { [WheelRouter]::Poke($list.Handle, $delta, $pt.X, $pt.Y) } catch { }
        try { $list.Update() } catch { }

        $si1 = [WheelRouter]::Vert($list.Handle)
        $pos1 = $(if ($null -eq $si1) { -1 } else { $si1[2] })

        # 列表动了 → 这格滚轮归它
        if ($pos1 -ne $pos0) { return $true }

        # 列表没动，但外层已经被它自己转发着滚过了 → 也算归它，别再滚一遍
        if ([Math]::Abs($body.AutoScrollPosition.Y) -ne $bodyBefore) { return $true }
    }

    # 二、列表滚到头（或光标不在列表上）：交给外层分区容器
    $target = Get-WheelScrollTarget -List $null -Body $body -Delta $delta
    if ($null -eq $target) { return $false }
    if ($target -eq [Math]::Abs($body.AutoScrollPosition.Y)) { return $false }

    try { $body.AutoScrollPosition = New-Object Drawing.Point(0, $target) } catch { return $false }
    return $true
}

try {
    Add-Type -TypeDefinition $wheelCode -ReferencedAssemblies System.Windows.Forms
    [WheelRouter]::Handler = [Func[IntPtr, int, bool]]$script:WheelHook
    [void][Windows.Forms.Application]::AddMessageFilter((New-Object WheelRouter))
} catch { }

$script:ListDoubleClick = {
    # 双击空白处不应该打开上一次选中的东西
    $pt = $this.PointToClient([Windows.Forms.Cursor]::Position)
    $hit = $this.HitTest($pt)
    if ($hit.Item) { Open-SelectedItem -Item $hit.Item -List $this }
}

$script:ListKeyDown = {
    param($keySender, $keyArgs)

    $target = $script:CurrentPath
    if ($this.Tag -and $this.Tag.Source) { $target = $this.Tag.Source.path }

    if ($keyArgs.Control -and $keyArgs.Shift -and $keyArgs.KeyCode -eq 'C') {
        # Ctrl+Shift+C = 复制文件地址，和资源管理器一致
        Copy-SelectedPath -List $this
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.Control -and $keyArgs.KeyCode -eq 'C') {
        Copy-Selected -List $this
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.Control -and $keyArgs.KeyCode -eq 'X') {
        Cut-Selected -List $this
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.Control -and $keyArgs.KeyCode -eq 'V') {
        Paste-Clipboard -Dest $target
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.Alt -and $keyArgs.KeyCode -eq 'Enter') {
        # Alt+Enter = 属性。必须放在普通 Enter 前面，否则会被「打开」抢走
        if ($this.SelectedItems.Count -gt 0) { Show-ItemProperties -Path $this.SelectedItems[0].Tag.Path }
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.KeyCode -eq 'F2') {
        Rename-Selected -List $this
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.KeyCode -eq 'Delete') {
        if ($this.SelectedItems.Count -gt 0) { Remove-ToRecycleBin -Paths (Get-SelectedPaths -List $this) }
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.KeyCode -eq 'Enter') {
        if ($this.SelectedItems.Count -gt 0) { Open-SelectedItem -Item $this.SelectedItems[0] -List $this }
        $keyArgs.Handled = $true
        $keyArgs.SuppressKeyPress = $true
    } elseif ($keyArgs.KeyCode -eq 'Back') {
        if ($script:History.Count -gt 0) {
            $p = $script:History.Pop()
            if ($p) { Show-Folder -Path $p -NoHistory } else { Show-Overview }
            $keyArgs.Handled = $true
        }
    }
}

# 选中项拖到资源管理器里 = 复制出去
function Test-CanStartListDrag {
    # 只有「左键真的还按着」才算拖拽开始。
    # 坑：双击打开文件后焦点被外部程序抢走，列表的 MouseUp 收不到，它就一直以为
    # 鼠标还按着；之后鼠标一动就自己发起拖拽，松手正好落在同一块上 → 全被跳过，
    # 只留下一句「已复制 0 项，跳过 1 项」。用户看到的就是「点一下文件，文件没打开，
    # 反而变成复制模式」。这里问的是系统的真实按键状态，键已经松了就不拖。
    return ([Windows.Forms.Control]::MouseButtons -eq [Windows.Forms.MouseButtons]::Left)
}

$script:ListItemDrag = {
    param($dragSender, $dragArgs)

    if (-not (Test-CanStartListDrag)) { return }

    $paths = @()
    foreach ($it in $this.SelectedItems) {
        if ($it.Tag -and $it.Tag.Path) { $paths += $it.Tag.Path }
    }
    if ($paths.Count -eq 0 -and $dragArgs.Item -and $dragArgs.Item.Tag) {
        $paths = @($dragArgs.Item.Tag.Path)
    }
    if ($paths.Count -eq 0) { return }

    $dobj = New-FileDropDataObject -Paths $paths
    if (-not $dobj) { return }
    [void]$this.DoDragDrop($dobj, [Windows.Forms.DragDropEffects]::Copy)
}

$script:lv.Add_DoubleClick($script:ListDoubleClick)
$script:lv.Add_KeyDown($script:ListKeyDown)
$script:lv.Add_ItemDrag($script:ListItemDrag)
$script:lv.Add_SelectedIndexChanged({ Update-SelectionInfo -List $this })
$script:lv.Add_MouseWheel($script:WheelToList)

$ctx = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $ctx.Items.Add('打开')
$miOpenWith = $ctx.Items.Add('打开方式…')
$miReveal = $ctx.Items.Add('在资源管理器中显示')
[void]$ctx.Items.Add('-')
$miCut = $ctx.Items.Add('剪切（Ctrl+X）')
$miCopyFiles = $ctx.Items.Add('复制（Ctrl+C）')
$miPaste = $ctx.Items.Add('粘贴到当前文件夹（Ctrl+V）')
[void]$ctx.Items.Add('-')
$miRename = $ctx.Items.Add('重命名（F2）')
$miDelete = $ctx.Items.Add('删除（Delete，进回收站）')
[void]$ctx.Items.Add('-')
$miNewFolder = $ctx.Items.Add('新建文件夹')
$miRefresh = $ctx.Items.Add('刷新')
[void]$ctx.Items.Add('-')
$miCopy = $ctx.Items.Add('复制文件地址（Ctrl+Shift+C）')
$miProps = $ctx.Items.Add('属性（Alt+Enter）')
$miShare = $ctx.Items.Add('共享…')
$miMore = New-Object Windows.Forms.ToolStripMenuItem('更多选项（系统菜单）')
$script:ShellComCache = @()
[void]$ctx.Items.Add($miMore)
[void]$ctx.Items.Add('-')
$miTop = New-Object Windows.Forms.ToolStripMenuItem('窗口置顶')
$miTop.CheckOnClick = $true
$miTop.Checked = $form.TopMost
$miTop.Add_Click({ $form.TopMost = $this.Checked })
[void]$ctx.Items.Add($miTop)
$miMoreTrans = $ctx.Items.Add('更透明一点')
$miLessTrans = $ctx.Items.Add('更不透明一点')

function Get-ContextTargetPath {
    # 菜单是从哪个列表弹出来的，就往哪个目录里操作
    $l = $script:CtxList
    if ($l -and $l.Tag -and $l.Tag.Source) { return $l.Tag.Source.path }
    return $script:CurrentPath
}

$applyOpacity = {
    param([double]$Delta)
    $v = [double]$form.Opacity + $Delta
    if ($v -lt 0.4) { $v = 0.4 }
    if ($v -gt 1) { $v = 1 }
    $v = [Math]::Round($v, 2)
    try { $form.Opacity = $v } catch { }
    $script:AppCfg.window.opacity = $v
    Save-Config $script:AppCfg | Out-Null
    $script:lblStatus.Text = ('背景不透明度 ' + [int]($v * 100) + '%')
}
$miMoreTrans.Add_Click({ & $applyOpacity -0.05 })
$miLessTrans.Add_Click({ & $applyOpacity 0.05 })

$ctx.Add_Opening({
    $src = $ctx.SourceControl
    $script:CtxList = $src
    $has = ($src -and $src.SelectedItems.Count -gt 0)
    $one = ($src -and $src.SelectedItems.Count -eq 1)
    $miOpen.Enabled = $has
    $miOpenWith.Enabled = $one
    $miReveal.Enabled = $has
    $miCut.Enabled = $has
    $miCopyFiles.Enabled = $has
    $miRename.Enabled = $one
    $miDelete.Enabled = $has
    $miCopy.Enabled = $has
    $miProps.Enabled = $one
    $miShare.Enabled = $one
    $target = Get-ContextTargetPath
    $miNewFolder.Enabled = [bool]$target
    $miPaste.Enabled = $false
    try {
        if ($target) { $miPaste.Enabled = [Windows.Forms.Clipboard]::ContainsFileDropList() }
    } catch { }

    # 「更多选项」每次弹出时现取一遍系统动词：文件类型不同，能用的动词也不同
    $miMore.DropDownItems.Clear()
    foreach ($o in $script:ShellComCache) {
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) } catch { }
    }
    $script:ShellComCache = @()
    $miMore.Enabled = $false

    if ($one) {
        $p = $src.SelectedItems[0].Tag.Path
        $verbs = @(Get-ShellVerbs -Path $p)
        foreach ($v in $verbs) { $script:ShellComCache += $v.Verb }

        # 上面已经有同名的项了，子菜单里不再重复
        $already = @('打开', '剪切', '复制', '删除', '重命名', '属性')
        $added = 0
        foreach ($v in $verbs) {
            $dup = $false
            foreach ($a in $already) { if ($v.Name.StartsWith($a)) { $dup = $true; break } }
            if ($dup) { continue }
            $it = New-Object Windows.Forms.ToolStripMenuItem($v.Name)
            $it.Tag = $v.Verb
            $it.Add_Click({
                try { $this.Tag.DoIt() } catch { $script:lblStatus.Text = '这个菜单项没能执行' }
            })
            [void]$miMore.DropDownItems.Add($it)
            $added++
            if ($added -ge 30) { break }
        }
        if ($added -gt 0) { $miMore.Enabled = $true }
    }
})

$miOpen.Add_Click({ Open-SelectedItem -List $script:CtxList })
$miOpenWith.Add_Click({
    $l = $script:CtxList
    if (-not $l -or $l.SelectedItems.Count -eq 0) { return }
    Open-WithDialog -Path $l.SelectedItems[0].Tag.Path
})
$miReveal.Add_Click({
    $l = $script:CtxList
    if (-not $l -or $l.SelectedItems.Count -eq 0) { return }
    $p = $l.SelectedItems[0].Tag.Path
    try { Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $p + '"') } catch { }
})
$miNewFolder.Add_Click({ New-FolderIn -Dir (Get-ContextTargetPath) })
$miCut.Add_Click({ Cut-Selected -List $script:CtxList })
$miCopyFiles.Add_Click({ Copy-Selected -List $script:CtxList })
$miPaste.Add_Click({ Paste-Clipboard -Dest (Get-ContextTargetPath) })
$miRename.Add_Click({ Rename-Selected -List $script:CtxList })
$miDelete.Add_Click({ Remove-ToRecycleBin -Paths (Get-SelectedPaths -List $script:CtxList) })
$miCopy.Add_Click({ Copy-SelectedPath -List $script:CtxList })
$miProps.Add_Click({
    $l = $script:CtxList
    if (-not $l -or $l.SelectedItems.Count -eq 0) { return }
    Show-ItemProperties -Path $l.SelectedItems[0].Tag.Path
})
$miShare.Add_Click({
    $l = $script:CtxList
    if (-not $l -or $l.SelectedItems.Count -eq 0) { return }
    $p = $l.SelectedItems[0].Tag.Path
    if (-not (Invoke-ShellVerbPrefix -Path $p -Prefix '共享')) {
        $script:lblStatus.Text = '这个项目没有「共享」选项'
    }
})
$miRefresh.Add_Click({ Refresh-CurrentView })
$script:lv.ContextMenuStrip = $ctx

# ------------------------------------------------------ 拖放：把东西拖进框
$dragEnterHandler = {
    param($dragSender, $dragArgs)
    if ($dragArgs.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) {
        $dragArgs.Effect = [Windows.Forms.DragDropEffects]::Copy
    } else {
        $dragArgs.Effect = [Windows.Forms.DragDropEffects]::None
    }
}
$dragDropHandler = {
    param($dropSender, $dropArgs)
    try {
        $paths = @($dropArgs.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        if ($paths.Count -eq 0) { return }

        # 框里已经打开了文件夹：拖进来 = 复制到这个文件夹
        if ($script:CurrentPath) {
            $real = @(Get-ForeignPaths -Paths $paths -Dir $script:CurrentPath)
            if ($real.Count -eq 0) { return }
            Copy-PathsInto -Paths $real -Dest $script:CurrentPath
            return
        }

        # 空框：拖进来的文件夹当作来源目录
        $added = 0
        foreach ($p in $paths) {
            if (Test-Path -LiteralPath $p -PathType Container) {
                Add-SourcePath $p
                $added++
            }
        }
        if ($added -eq 0) {
            [Windows.Forms.MessageBox]::Show('框里还没有打开的文件夹。请先拖一个文件夹进来当来源，或点 ⚙ 添加目录。', '桌面框', 'OK', 'Information') | Out-Null
        }
    } catch { }
}
foreach ($dc in @($script:lv, $script:pnlEmpty, $form)) {
    $dc.AllowDrop = $true
    $dc.Add_DragEnter($dragEnterHandler)
    $dc.Add_DragDrop($dragDropHandler)
}

$form.Add_Resize({ Update-Layout })
$form.Add_Paint({
    param($paintSender, $paintArgs)
    try {
        $g = $paintArgs.Graphics
        $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $this.Width; $h = $this.Height
        if ($w -lt 40 -or $h -lt 40) { return }
        $r = 10; $d = $r * 2
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $d, $d, 180, 90)
        $p.AddArc($w - $d - 1, 0, $d, $d, 270, 90)
        $p.AddArc($w - $d - 1, $h - $d - 1, $d, $d, 0, 90)
        $p.AddArc(0, $h - $d - 1, $d, $d, 90, 90)
        $p.CloseFigure()
        $pen = New-Object Drawing.Pen($clrBorder, 1)
        $g.DrawPath($pen, $p)
        $pen.Dispose()
        $p.Dispose()
    } catch { }
})

# 首次启动（配置里还没有目录）时自动把设置窗口弹出来，
# 否则用户只会看到一个空框，以为程序没工作。
$script:guideTimer = New-Object Windows.Forms.Timer
$script:guideTimer.Interval = 400
$script:guideTimer.Add_Tick({
    $script:guideTimer.Stop()
    Show-Settings
})

$form.Add_Shown({
    Update-Layout
    if ($script:Sources.Count -gt 0) {
        Show-AllSources
        # 窗体真正显示出来后容器才完成滚动计算，这里再压一次，保证开箱从顶部看
        if ($script:pnlBody) { try { $script:pnlBody.AutoScrollPosition = New-Object Drawing.Point(0, 0) } catch { } }
    } else {
        $script:pnlEmpty.Visible = $true
        $script:lv.Visible = $false
        $script:lblStatus.Text = '等待添加目录 · 也可以直接把文件夹拖进这个框'
        Update-Layout
        $script:guideTimer.Start()
    }
})

$form.Add_FormClosing({
    try {
        $script:AppCfg.window.x = $this.Left
        $script:AppCfg.window.y = $this.Top
        $script:AppCfg.window.width = $this.Width
        $script:AppCfg.window.height = if ($script:Collapsed) { $script:ExpandedHeight } else { $this.Height }
        $script:AppCfg.window.topmost = $this.TopMost
        $script:AppCfg.window.opacity = $this.Opacity
        $script:AppCfg.sources = @($script:Sources)
        # 分区高度也记下来，开机自动启动时才叫「上次关闭前的状态」
        $bh = @()
        try {
            foreach ($k in @($script:BlockHeights.Keys)) {
                $v = 0
                try { $v = [int]$script:BlockHeights[$k] } catch { continue }
                if ($v -lt 92 -or $v -gt 4000) { continue }
                $bh += [pscustomobject]@{ path = [string]$k; h = $v }
            }
        } catch { }
        $script:AppCfg.window.blockHeights = $bh
        Save-Config $script:AppCfg | Out-Null
    } catch { }
})

# ---------------------------------------------------------------- 托盘与开关
$script:ni = New-Object Windows.Forms.NotifyIcon
try {
    $script:ni.Icon = [Drawing.Icon]::ExtractAssociatedIcon((Join-Path $env:SystemRoot 'explorer.exe'))
} catch {
    $script:ni.Icon = [Drawing.SystemIcons]::Application
}
$trayText = [string]$script:AppCfg.title
if ($trayText.Length -gt 63) { $trayText = $trayText.Substring(0, 63) }
$script:ni.Text = $trayText
$script:ni.Visible = $true

$toggleWindow = {
    if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.Activate() }
}
$script:ni.Add_DoubleClick($toggleWindow)

$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$miTrayToggle = $trayMenu.Items.Add('显示 / 隐藏')
$miTrayExit = $trayMenu.Items.Add('退出桌面框')
$miTrayToggle.Add_Click($toggleWindow)
$miTrayExit.Add_Click({ $form.Close() })
$script:ni.ContextMenuStrip = $trayMenu

# 双击桌面图标（已运行时）会写下 .toggle，这里轮询后切换显示状态
$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 400
$script:timer.Add_Tick({
    if (Test-Path -LiteralPath $script:ToggleFlag) {
        Remove-Item -LiteralPath $script:ToggleFlag -Force -ErrorAction SilentlyContinue
        if ($form.Visible) { $form.Hide() } else { $form.Show(); $form.Activate() }
    }
})
$script:timer.Start()

$form.Add_FormClosed({
    try { $script:timer.Stop(); $script:timer.Dispose() } catch { }
    try { $script:guideTimer.Stop(); $script:guideTimer.Dispose() } catch { }
    try { $script:ni.Visible = $false; $script:ni.Dispose() } catch { }
    try { if ($script:InstanceMutex) { $script:InstanceMutex.Dispose() } } catch { }
    try { if (Test-Path -LiteralPath $script:ToggleFlag) { Remove-Item -LiteralPath $script:ToggleFlag -Force } } catch { }
})

if ($SelfCheck) {
    $script:SelfCheckFail = 0
    function Step {
        param([string]$Name, [scriptblock]$Action)
        $ErrorActionPreference = 'Stop'
        try {
            & $Action
            Write-Output ('  OK   ' + $Name)
        } catch {
            $script:SelfCheckFail++
            Write-Output ('  FAIL ' + $Name + ' :: ' + $_.Exception.Message)
        }
    }

    # 自检的「保存配置」写的是临时文件（见 $SelfCheck 时的 ConfigPath 重定向），
    # 用户的 config.json 从头到尾只读不写，跑完把临时文件删掉即可。
    $cfgBackup = $null

    # 自检时窗体从来没 Show 出来，Control.Visible 会一路是 False（父级不可见），
    # 读不到「我们到底设成显示还是隐藏」，所以直接读控件自身那份状态位。
    function Get-Shown {
        param($c)
        if (-not $c) { return $false }
        $m = $c.GetType().GetMethod('GetState', [Reflection.BindingFlags]'Instance,NonPublic')
        if ($m) { return [bool]$m.Invoke($c, @(2)) }
        return [bool]$c.Visible
    }

    Write-Output 'SELFCHECK START'
    Write-Output ('       config = ' + $(if ($script:ConfigRealPath) { $script:ConfigRealPath + '  (只读，写入走临时文件)' } else { $script:ConfigPath }))
    Step 'Mutex acquired' { if (-not $script:InstanceMutex) { throw 'mutex null' } }
    Step 'Update-Layout' { Update-Layout }

    # 自检要摆弄分区，而分区是从「来源列表」来的。全新安装（或者把来源删光）时
    # 列表是空的，后面所有取 $script:Blocks[0] 的检查项会整片挂掉——那是自检
    # 自己没准备场地，不是程序有问题。所以先临时塞一个来源（程序目录本身），
    # 全部跑完再撤掉；config 文件全程只写临时文件，不会被污染。
    $selfTmpSource = $false
    if (@($script:Sources | Where-Object { $_.path }).Count -eq 0) {
        $selfTmpSource = $true
        $script:Sources = @([pscustomobject]@{ name = 'selftest'; path = $script:Root })
        $script:AppCfg.sources = $script:Sources
        Show-AllSources
        Write-Output ('       （没有来源，临时用程序目录当第 1 个分区跑后面的检查）')
    }

    Step '分区视图（多块 + 块内滚动）' {
        $saved = @($script:Sources)
        try {
            $script:Sources = @($saved) + @([pscustomobject]@{ name = 'selftest'; path = $script:Root })
            Show-AllSources

            $expect = @($script:Sources | Where-Object { $_.path }).Count
            if ($script:Blocks.Count -ne $expect) {
                throw ('blocks=' + $script:Blocks.Count + ' expect=' + $expect)
            }
            if (-not (Get-Shown $script:pnlBody)) { throw '分区容器没显示' }
            if (Get-Shown $script:lv) { throw '单目录列表没隐藏' }

            $first = $script:Blocks[0]
            if (-not $first.List -or $first.List.Items.Count -lt 1) { throw '第一个分区没内容' }
            if (-not $first.List.Scrollable) { throw '分区内不能滚动' }

            Write-Output ('       ' + $script:Blocks.Count + ' 块 / 首块 ' + $first.List.Items.Count + ' 项 / 高 ' + $first.Height)
            foreach ($bb in $script:Blocks) {
                Write-Output ('         · ' + $bb.Source.name + ' items=' + $bb.List.Items.Count + ' want=' + $bb.Height + ' real=' + $bb.Panel.Height)
            }
        } finally {
            $script:Sources = $saved
            Show-AllSources
        }
    }

    Step '分区高度开关和「固定」无关' {
        # 固定只管窗口位置：不管锁定与否，那条 6px 横条都得是可拖的
        if (-not (Test-CanResizeBlock)) { throw '分区高度不该受固定状态影响' }
        Rebuild-Blocks
        $bad = @()
        foreach ($b in $script:Blocks) {
            if (-not $b.Grip.Enabled) { $bad += $b.Source.name }
            if ($b.Grip.Cursor -ne [Windows.Forms.Cursors]::SizeNS) { $bad += $b.Source.name }
        }
        if ($bad.Count -gt 0) { throw ('这些分区的手柄拖不动：' + ($bad -join ' / ')) }
        Write-Output ('       ' + $script:Blocks.Count + ' 块横条均可拖（locked=' + $script:Locked + '）')
    }

    Step '分区高度会被记住（重建 / 重启都还原）' {
        $p0 = [string]$script:Sources[0].path
        $keep = $null
        $had = $script:BlockHeights.ContainsKey($p0)
        if ($had) { $keep = $script:BlockHeights[$p0] }
        try {
            $script:BlockHeights[$p0] = 260
            Rebuild-Blocks
            $b0 = $script:Blocks[0]
            if ([int]$b0.Height -ne 260) { throw ('重建后没按记住的高度：' + $b0.Height) }
            if ([int]$b0.Panel.Height -ne 260) { throw ('布局没跟上：' + $b0.Panel.Height) }

            # 写进 config 再读回来，相当于「关掉再开机」
            $script:AppCfg.window.blockHeights = @([pscustomobject]@{ path = $p0; h = 260 })
            if (-not (Save-Config $script:AppCfg)) { throw 'save failed' }
            $back = Read-Config
            $hit = $null
            foreach ($e in @($back.window.blockHeights)) {
                if ($e -and [string]$e.path -eq $p0) { $hit = [int]$e.h }
            }
            if ($hit -ne 260) { throw ('config 里读不回高度：' + [string]$hit) }
        } finally {
            if ($had) { $script:BlockHeights[$p0] = $keep } else { try { $script:BlockHeights.Remove($p0) } catch { } }
            $script:AppCfg.window.blockHeights = @()
            Rebuild-Blocks
        }
    }

    Step '分区折叠 / 展开' {
        $b = $script:Blocks[0]
        $h0 = $b.Height
        $b.Collapsed = $true
        Update-BlockLayout
        if (Get-Shown $b.List) { throw '折叠后列表还显示着' }
        if ($b.Panel.Height -ne $script:BlockHeaderH) { throw ('折叠高度=' + $b.Panel.Height) }
        $b.Collapsed = $false
        Update-BlockLayout
        if (-not (Get-Shown $b.List)) { throw '展开后列表没出来' }
        if ($b.Panel.Height -ne $h0) { throw '展开后高度不对' }
    }

    Step '拖动改分区高度' {
        $b = $script:Blocks[0]
        $old = $b.Height
        $b.Height = $old + 60
        Update-BlockLayout
        if ($b.Panel.Height -ne ($old + 60)) { throw ('panel=' + $b.Panel.Height) }
        $b.Height = $old
        Update-BlockLayout
    }

    Step '滚动状态下重排不跑偏（上方空白 bug）' {
        # 复现用户遇到的情况：容器已经滚下去了，此时又做了一次布局
        $body = $script:pnlBody
        $b0 = $script:Blocks[0]
        $body.AutoScrollMinSize = New-Object Drawing.Size(0, 4000)
        $body.AutoScrollPosition = New-Object Drawing.Point(0, 120)
        Update-BlockLayout
        $body.AutoScrollMinSize = New-Object Drawing.Size(0, 0)
        Update-BlockLayout
        if ($b0.Panel.Top -ne 0) { throw ('第一块被推到 y=' + $b0.Panel.Top + '，上方会空出一片') }
        if ($body.AutoScrollPosition.Y -ne 0) { throw ('内容装得下却还滚着：' + $body.AutoScrollPosition.Y) }
    }

    Step '四边四角调大小手柄' {
        Update-Layout
        if (-not $script:Edges -or $script:Edges.Count -ne 4) { throw '边手柄不是 4 个' }
        if (-not $script:Corners -or $script:Corners.Count -ne 4) { throw '角手柄不是 4 个' }

        $w = $form.ClientSize.Width
        $h = $form.ClientSize.Height
        if ($script:Edges['N'].Top -ne 0) { throw '上边手柄没贴顶' }
        if ($script:Edges['N'].Width -ne $w) { throw '上边手柄没横向铺满' }
        if ($script:Edges['S'].Bottom -ne $h) { throw ('下边手柄没贴底：' + $script:Edges['S'].Bottom + '/' + $h) }
        if ($script:Edges['W'].Left -ne 0) { throw '左边手柄没贴左' }
        if ($script:Edges['E'].Right -ne $w) { throw ('右边手柄没贴右：' + $script:Edges['E'].Right + '/' + $w) }
        if ($script:Corners['SE'].Right -ne $w -or $script:Corners['SE'].Bottom -ne $h) { throw '右下角手柄没贴角' }
        if ($script:Corners['NW'].Left -ne 0 -or $script:Corners['NW'].Top -ne 0) { throw '左上角手柄没贴角' }

        if ($script:Edges['E'].Cursor -ne [Windows.Forms.Cursors]::SizeWE) { throw '右边光标不是左右箭头' }
        if ($script:Edges['N'].Cursor -ne [Windows.Forms.Cursors]::SizeNS) { throw '上边光标不是上下箭头' }
        if ($script:Corners['NE'].Cursor -ne [Windows.Forms.Cursors]::SizeNESW) { throw '右上角光标不对' }
        if ($script:Corners['SE'].Cursor -ne [Windows.Forms.Cursors]::SizeNWSE) { throw '右下角光标不对' }

        # 尺寸变了手柄要跟着走
        $ow = $form.Width; $oh = $form.Height
        try {
            $form.Size = New-Object Drawing.Size(640, 520)
            Update-Layout
            if ($script:Corners['SE'].Right -ne $form.ClientSize.Width) { throw '改宽后右上角没跟着走' }
            if ($script:Corners['SE'].Bottom -ne $form.ClientSize.Height) { throw '改高后右下角没跟着走' }
        } finally {
            $form.Size = New-Object Drawing.Size($ow, $oh)
            Update-Layout
        }

        # 真的走一遍缩放计算。用 -TestDx/-TestDy 直接给定位移：
        # 若靠「按下点 = 光标 - 期望位移」来造 dx，光标在自检期间一动结果就漂（实测差过 4px）。
        $ob = $form.Bounds
        $minW = $script:MinWinW
        $minH = $script:MinWinH
        try {
            # 先放大一点，免得一开始就卡在最小尺寸上（默认窗口正好是 520 宽）
            $form.SetBounds($ob.X, $ob.Y, [Math]::Max($ob.Width, 800), [Math]::Max($ob.Height, 600))
            Update-Layout

            $base = $form.Bounds
            $script:EdgeZone = 'SE'
            $script:EdgeRect = $form.Bounds
            & $script:ResizeMove -TestDx 40 -TestDy 30
            if ($form.Width -ne ($base.Width + 40)) { throw ('右下角拉宽算错：' + $form.Width + ' 应为 ' + ($base.Width + 40)) }
            if ($form.Height -ne ($base.Height + 30)) { throw ('右下角拉高算错：' + $form.Height + ' 应为 ' + ($base.Height + 30)) }

            # 往左拉左边（dx 为负）：左边界左移、右边不动、宽度变大
            $form.SetBounds($base.X, $base.Y, $base.Width, $base.Height)
            $script:EdgeZone = 'W'
            $script:EdgeRect = $form.Bounds
            & $script:ResizeMove -TestDx (-60) -TestDy 0
            if ($form.Left -ne ($base.X - 60)) { throw ('左边界没跟着动：' + $form.Left + ' 应为 ' + ($base.X - 60)) }
            if ($form.Right -ne $base.Right) { throw ('拉左边时右边不该动：' + $form.Right + '/' + $base.Right) }
            if ($form.Width -ne ($base.Width + 60)) { throw ('宽度没跟上：' + $form.Width) }

            # 缩到极限要卡在最小尺寸，不能缩成 0 或负数
            $form.SetBounds($base.X, $base.Y, $base.Width, $base.Height)
            $script:EdgeZone = 'SE'
            $script:EdgeRect = $form.Bounds
            & $script:ResizeMove -TestDx (-5000) -TestDy (-5000)
            if ($form.Width -ne $minW) { throw ('没卡在最小宽度：' + $form.Width + ' 应为 ' + $minW) }
            if ($form.Height -ne $minH) { throw ('没卡在最小高度：' + $form.Height + ' 应为 ' + $minH) }
        } finally {
            $script:EdgeZone = $null
            $form.SetBounds($ob.X, $ob.Y, $ob.Width, $ob.Height)
            Update-Layout
        }
    }

    Step '单目录视图' {
        Show-Folder -Path $script:Root -NoHistory
        if (Get-Shown $script:pnlBody) { throw '分区容器没隐藏' }
        if (-not (Get-Shown $script:lv)) { throw '单目录列表没显示' }
        if ($script:lv.Items.Count -lt 1) { throw 'no items' }
        Write-Output ('       ' + $script:lv.Items.Count + ' 项')
    }

    Step '回到分区视图' {
        Show-Overview
        if (-not (Get-Shown $script:pnlBody)) { throw '分区容器没显示' }
        if (Get-Shown $script:lv) { throw '单目录列表没隐藏' }
        if ($script:Blocks.Count -lt 1) { throw 'blocks=0' }
    }
    Step 'Icons loaded' { if ($script:lv.SmallImageList.Images.Count -lt 1) { throw 'image list empty' } }
    Step 'Icon API' { if (-not $iconCode) { throw 'Add-Type failed, icons degraded' } }
    Step 'Type name' {
        if (-not $iconCode) { throw 'skip' }
        $t = [ShellIcon]::GetTypeName($script:Root, $true)
        if (-not $t) { throw 'empty type name' }
    }
    Step 'NotifyIcon' { $n = New-Object Windows.Forms.NotifyIcon; $n.Icon = $script:ni.Icon; $n.Dispose() }
    Step 'Collapse toggle' {
        $h0 = $form.Height
        Toggle-Collapse
        # 收起高度 = 窗口下限（顶部路径条去掉后是 42）；写成引用下限，改版时不用再改断言
        if ($form.Height -ne $form.MinimumSize.Height) { throw ('收起后应该贴到最低高度 ' + $form.MinimumSize.Height + '，实际 ' + $form.Height) }
        Toggle-Collapse
        if ($form.Height -lt 200) { throw ('展开后高度异常：' + $form.Height) }
        if ([Math]::Abs($form.Height - $h0) -gt 4) { throw ('展开后没回到原高：' + $form.Height + ' 原 ' + $h0) }
        # 分区总览下收起再展开，不能把那个空的单目录列表拉开盖在所有分区上面
        # （旧版就是这里出问题：看图是「框回来了，里面一片空白，只剩一个『名称』表头」）
        if ((Get-Shown $script:lv) -and (Get-Shown $script:pnlBody)) { throw '收起展开后列表和分区同时显示，会互相遮挡' }
        if (-not (Get-Shown $script:pnlBody)) { throw '分区总览下展开后分区容器没还原' }
    }
    Step 'Collapse toggle（单目录视图）' {
        $p0 = @($script:Sources)[0].path
        Show-Folder -Path $p0 -NoHistory
        Toggle-Collapse
        Toggle-Collapse
        if (-not (Get-Shown $script:lv)) { throw '单目录视图展开后列表没还原' }
        if (Get-Shown $script:pnlBody) { throw '单目录视图展开后分区容器不该露出来' }
        Show-Overview
    }
    Step '固定（只锁位置，其余都能调）' {
        # 用户可能上次退出时是「固定」状态（config.window.locked = true），
        # 那样启动就带着锁，第一条断言天然不成立 —— 先复位成解锁再测
        if ($script:Locked) { Set-Locked $false }
        if (-not (Get-Shown $script:Edges['N'])) { throw '默认状态下四边手柄应该是露着的' }
        if ((Get-Shown $script:pnlBody) -and $script:Blocks.Count -lt 1) { throw '分区总览下应该有分区可测' }
        $bb = $null
        if ($script:Blocks.Count -gt 0) { $bb = $script:Blocks[0] }
        Set-Locked $true
        # 固定只锁位置：四边四角手柄必须还在，窗口大小照样能拉
        if (-not (Get-Shown $script:Edges['N'])) { throw '锁定后四边手柄被藏掉了，大小就调不了了' }
        if (-not (Get-Shown $script:Corners['SE'])) { throw '锁定后四角手柄被藏掉了，大小就调不了了' }
        if ($script:Edges['N'].Cursor -ne [Windows.Forms.Cursors]::SizeNS) { throw '锁定后上边手柄光标不对' }

        # 锁定状态下真拉一次边：宽度必须变，位置里没被拉的那条边必须不动
        $ob = $form.Bounds
        try {
            $script:EdgeZone = $null
            & $script:ResizeZone 'E'
            if (-not $script:EdgeZone) { throw '锁定后拉右边被拦下来了' }
            $script:EdgeRect = $form.Bounds
            & $script:ResizeMove -TestDx 40 -TestDy 0
            if ($form.Width -ne ($ob.Width + 40)) { throw ('锁定后拉右边没变宽：' + $form.Width + ' 应为 ' + ($ob.Width + 40)) }
            if ($form.Left -ne $ob.Left) { throw '只拉右边不该改左边界' }
        } finally {
            $script:EdgeZone = $null
            $form.SetBounds($ob.X, $ob.Y, $ob.Width, $ob.Height)
            Update-Layout
        }

        # 位置仍然锁死：拖标题栏不许动
        $script:Dragging = $false
        & $startDrag
        if ($script:Dragging) { throw '锁定后还能拖动窗口' }

        # 分区之间那条横条不受影响：锁定态下照样能拖高
        if (-not (Test-CanResizeBlock)) { throw '锁定后分区高度被冻住了，应该还能调' }
        if ($bb) {
            if (-not $bb.Grip.Enabled) { throw '锁定后分区手柄被禁用了，应该还能拖' }
            if ($bb.Grip.Cursor -ne [Windows.Forms.Cursors]::SizeNS) { throw '锁定后分区手柄光标不是上下双箭头' }
            # 真拖一下：锁定态下高度必须能改，改完布局要跟着走
            $h0 = $bb.Height
            $bb.Height = $h0 + 40
            Update-BlockLayout
            if ($bb.Height -ne ($h0 + 40)) { throw ('锁定状态下拖不动高度：' + $h0 + ' -> ' + $bb.Height) }
            if ($bb.Panel.Height -ne ($h0 + 40)) { throw ('锁定状态下布局没跟上：' + $bb.Panel.Height) }
            $bb.Height = $h0
            Update-BlockLayout
            if ($bb.Panel.Height -ne $h0) { throw ('高度没还原：' + $bb.Panel.Height) }
        }
        Set-Locked $false
        if (-not (Get-Shown $script:Edges['N'])) { throw '解锁后四边手柄没回来' }
        if (-not (Test-CanResizeBlock)) { throw '解锁后不允许拖分区高度' }
        if ($bb) {
            if (-not $bb.Grip.Enabled) { throw '解锁后分区手柄没好' }
            if ($bb.Grip.Cursor -ne [Windows.Forms.Cursors]::SizeNS) { throw '解锁后分区手柄光标不对' }
        }
        $script:Dragging = $false
        & $startDrag
        if (-not $script:Dragging) { throw '解锁后拖不动窗口了' }
        $script:Dragging = $false
    }
    Step '滚轮转发到分区容器' {
        # 列表装得下 → 滚轮应该转给外层容器（往下滚一格 = 60px）
        $fakeList = New-Object psobject -Property @{
            ClientSize = (New-Object Drawing.Size(400, 300))
            Items      = @(1, 2, 3)
            TopItem    = $null
        }
        $fakeBody = New-Object psobject -Property @{
            AutoScrollMinSize  = (New-Object Drawing.Size(0, 4000))
            ClientSize         = (New-Object Drawing.Size(400, 260))
            AutoScrollPosition = (New-Object Drawing.Point(0, 0))
        }
        $t1 = Get-WheelScrollTarget -List $fakeList -Body $fakeBody -Delta -120
        if ($t1 -ne 60) { throw ('往下滚一格应该到 60，实际 ' + $t1) }
        $t2 = Get-WheelScrollTarget -List $fakeList -Body $fakeBody -Delta 120
        if ($t2 -ne 0) { throw ('已经在顶部再往上滚应该还是 0，实际 ' + $t2) }

        # 列表滚到一半、这个方向还有内容 → 让它自己滚，不许抢
        $midList = New-Object psobject -Property @{
            ClientSize = (New-Object Drawing.Size(400, 300))
            Items      = (1..80)
            TopItem    = (New-Object psobject -Property @{ Index = 10 })
        }
        if ($null -ne (Get-WheelScrollTarget -List $midList -Body $fakeBody -Delta -120)) {
            throw '列表下面还有内容时不该接管滚轮'
        }
        if ($null -ne (Get-WheelScrollTarget -List $midList -Body $fakeBody -Delta 120)) {
            throw '列表上面还有内容时不该接管滚轮'
        }

        # 列表已经滚到底 → 让位给外层（用户报的就是这个场景：滚了跟没滚一样）
        $bottomList = New-Object psobject -Property @{
            ClientSize = (New-Object Drawing.Size(400, 300))
            Items      = (1..80)
            TopItem    = (New-Object psobject -Property @{ Index = 77 })
        }
        $t3 = Get-WheelScrollTarget -List $bottomList -Body $fakeBody -Delta -120
        if ($null -eq $t3) { throw '列表滚到底之后应该把滚轮交给外层容器' }

        # 列表在顶部往上滚 → 让位给外层
        $topList = New-Object psobject -Property @{
            ClientSize = (New-Object Drawing.Size(400, 300))
            Items      = (1..80)
            TopItem    = (New-Object psobject -Property @{ Index = 0 })
        }
        if ($null -eq (Get-WheelScrollTarget -List $topList -Body $fakeBody -Delta 120)) {
            throw '列表在顶部还往上滚时应该交给外层容器'
        }

        # 外层压根没得滚 → 什么都不做
        $shortBody = New-Object psobject -Property @{
            AutoScrollMinSize  = (New-Object Drawing.Size(0, 0))
            ClientSize         = (New-Object Drawing.Size(400, 260))
            AutoScrollPosition = (New-Object Drawing.Point(0, 0))
        }
        if ($null -ne (Get-WheelScrollTarget -List $fakeList -Body $shortBody -Delta -120)) {
            throw '容器没得滚的时候不该返回目标位置'
        }
    }
    Step '滚轮：列表先滚，到边界交给外层' {
        if (-not ('WheelRouter' -as [type])) { throw 'WheelRouter 类型没编译出来' }
        # 判断「列表还能不能滚」靠的是 GetScrollInfo / SendMessage，不是估行数
        if (-not [WheelRouter].GetMethod('Vert')) { throw 'WheelRouter.Vert 缺失' }
        if (-not [WheelRouter].GetMethod('Poke')) { throw 'WheelRouter.Poke 缺失' }
        if ($null -ne [WheelRouter]::Vert([IntPtr]::Zero)) {
            throw '给无效句柄取滚动信息不该有结果'
        }
        # 外层这一层仍然是纯计算，照旧断言
        $fakeList = New-Object psobject -Property @{ Items = (New-Object psobject); TopItem = $null }
        $tallBody = New-Object psobject -Property @{
            AutoScrollMinSize  = (New-Object Drawing.Size(0, 1000))
            ClientSize         = (New-Object Drawing.Size(400, 260))
            AutoScrollPosition = (New-Object Drawing.Point(0, 0))
        }
        if (-not ((Get-WheelScrollTarget -List $null -Body $tallBody -Delta -120) -gt 0)) {
            throw '内容超高时往下滚应该有目标位置'
        }
    }
    Step '滚轮消息过滤器已装' {
        if (-not ('WheelRouter' -as [type])) { throw 'WheelRouter 类型没编译出来' }
        if ($null -eq [WheelRouter]::Handler) { throw '滚轮回调没挂上（ScriptBlock 转委托失败）' }
    }
    Step 'Rebuild-Tabs' { Rebuild-Tabs }
    Step 'Drag handlers' { if (-not $script:lv.AllowDrop) { throw 'drop not enabled' } }

    Step 'File copy engine' {
        $t = Join-Path $env:TEMP ('box_selftest_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        try {
            $src = Join-Path $t 'src'; New-Item -ItemType Directory -Path $src -Force | Out-Null
            $dst = Join-Path $t 'dst'; New-Item -ItemType Directory -Path $dst -Force | Out-Null
            $f1 = Join-Path $src 'a.txt'
            [IO.File]::WriteAllText($f1, 'hello')

            Copy-PathsInto -Paths @($f1) -Dest $dst -Quiet
            if (-not (Test-Path -LiteralPath (Join-Path $dst 'a.txt'))) { throw '文件没有复制过去' }

            Copy-PathsInto -Paths @($f1) -Dest $dst -Quiet
            if (-not (Test-Path -LiteralPath (Join-Path $dst 'a (2).txt'))) { throw '重名没有自动改名' }

            # 把源目录拖进它自己的子目录，必须被跳过而不是无限复制
            $inner = Join-Path $src 'inner'; New-Item -ItemType Directory -Path $inner -Force | Out-Null
            Copy-PathsInto -Paths @($src) -Dest $inner -Quiet
            if (Test-Path -LiteralPath (Join-Path $inner 'src')) { throw '把父目录复制进了自己的子目录' }
        } finally {
            try { [System.IO.Directory]::Delete($t, $true) } catch { }
        }
    }

    Step 'Clipboard files' {
        $tmpF = Join-Path $env:TEMP ('box_clip_' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        try {
            [IO.File]::WriteAllText($tmpF, 'x')
            if (-not (Set-ClipboardFiles @($tmpF))) { throw '写入剪贴板失败' }
            $back = Get-ClipboardFiles
            if ($back.Count -lt 1) { throw '读回剪贴板为空' }
        } finally {
            try { [IO.File]::Delete($tmpF) } catch { }
        }
    }

    Step '资源管理器操作（移动 / 剪切 / 回收站）' {
        $t = Join-Path $env:TEMP ('box_expl_' + [Guid]::NewGuid().ToString('N').Substring(0, 6))
        try {
            $src = Join-Path $t 'src'; New-Item -ItemType Directory -Path $src -Force | Out-Null
            $dst = Join-Path $t 'dst'; New-Item -ItemType Directory -Path $dst -Force | Out-Null

            # 移动：源文件应该从 src 消失、出现在 dst
            $f1 = Join-Path $src 'm.txt'
            [IO.File]::WriteAllText($f1, 'm')
            Move-PathsInto -Paths @($f1) -Dest $dst -Quiet
            if (Test-Path -LiteralPath $f1) { throw '移动后源文件还在' }
            if (-not (Test-Path -LiteralPath (Join-Path $dst 'm.txt'))) { throw '移动后目标里没有' }

            # 移动进自己的子目录必须跳过
            $inner = Join-Path $src 'inner'; New-Item -ItemType Directory -Path $inner -Force | Out-Null
            Move-PathsInto -Paths @($src) -Dest $inner -Quiet
            if (Test-Path -LiteralPath (Join-Path $inner 'src')) { throw '把父目录移动进了自己的子目录' }

            # 剪切写进剪贴板的标记必须是 2（Move），复制是 1。
            # 这里直接查数据对象本身：走系统剪贴板读回来会被剪贴板管理器插一手，断言时灵时不灵。
            $o1 = New-FileDropDataObject -Paths @($f1) -Move
            $s1 = $o1.GetData('Preferred DropEffect')
            $buf1 = New-Object byte[] 4
            $null = $s1.Read($buf1, 0, 4)
            if ([BitConverter]::ToInt32($buf1, 0) -ne 2) { throw '剪切的 DropEffect 不是 2' }

            $o2 = New-FileDropDataObject -Paths @($f1)
            $s2 = $o2.GetData('Preferred DropEffect')
            $buf2 = New-Object byte[] 4
            $null = $s2.Read($buf2, 0, 4)
            if ([BitConverter]::ToInt32($buf2, 0) -ne 1) { throw '复制的 DropEffect 不是 1' }

            if (-not (Set-ClipboardFiles @($f1) -Move)) { throw '剪切写剪贴板失败' }

            # 回收站那套 API 能加载（真删留给用户操作，自检不往回收站里塞东西）
            try { Add-Type -AssemblyName Microsoft.VisualBasic } catch { }
            if (-not ('Microsoft.VisualBasic.FileIO.FileSystem' -as [type])) { throw '回收站 API 不可用' }
        } finally {
            try { [System.IO.Directory]::Delete($t, $true) } catch { }
        }
    }

    Step '右键菜单（资源管理器那套）' {
        $want = @('打开', '打开方式…', '在资源管理器中显示', '剪切（Ctrl+X）', '复制（Ctrl+C）',
                  '粘贴到当前文件夹（Ctrl+V）', '重命名（F2）', '删除（Delete，进回收站）',
                  '新建文件夹', '刷新', '复制文件地址（Ctrl+Shift+C）', '属性（Alt+Enter）',
                  '共享…', '更多选项（系统菜单）', '窗口置顶', '更透明一点', '更不透明一点')
        $got = @()
        foreach ($i in $ctx.Items) {
            if ($i -is [Windows.Forms.ToolStripSeparator]) { continue }
            $got += [string]$i.Text
        }
        if (($got -join '|') -ne ($want -join '|')) {
            throw ('菜单项不对：' + ($got -join ' / '))
        }
        # 系统动词能取到（拿脚本自己当样本）
        $self = $MyInvocation.MyCommand.Path
        if ($self -and (Test-Path -LiteralPath $self)) {
            $vs = @(Get-ShellVerbs -Path $self)
            if ($vs.Count -lt 1) { throw '取不到系统动词' }
        }
    }

    Step '选中项信息（大小 / 修改时间）' {
        if ((Format-FileSize 512) -notlike '*B*') { throw '字节档格式化错了' }
        if ((Format-FileSize 2048) -notlike '*KB*') { throw 'KB 档不对' }
        if ((Format-FileSize 3145728) -notlike '*MB*') { throw 'MB 档不对' }

        $f = Join-Path $env:TEMP ('size_' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        try {
            [IO.File]::WriteAllText($f, ('x' * 2000))
            $fake = New-Object psobject -Property @{
                SelectedItems = @([pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f; IsDir = $false } })
            }
            $script:lblStatus.Text = '原样'
            Update-SelectionInfo -List $fake
            $txt = $script:lblStatus.Text
            if ($txt -notlike '*KB*') { throw ('没显示大小：' + $txt) }
            if ($txt -notlike '*修改于*') { throw ('没显示修改时间：' + $txt) }

            $fake2 = New-Object psobject -Property @{
                SelectedItems = @(
                    [pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f; IsDir = $false } },
                    [pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f; IsDir = $false } }
                )
            }
            $script:lblStatus.Text = ''
            Update-SelectionInfo -List $fake2
            if ($script:lblStatus.Text -notlike '已选中 2 项*') { throw ('多选没报数量：' + $script:lblStatus.Text) }
        } finally {
            try { [IO.File]::Delete($f) } catch { }
        }
    }

    Step '复制文件地址（整条路径，不是首字符）' {
        # 这条专治「复制出来只有一个 E」：Get-SelectedPaths 的 return @($out)
        # 在只有一个元素时会被管道拆成裸字符串，调用侧不加 @() 就会取到第一个字符
        $f = Join-Path $env:TEMP ('cp_' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
        $f2 = $f + '.bak'
        try {
            [IO.File]::WriteAllText($f, 'x')
            $one = New-Object psobject -Property @{
                SelectedItems = @([pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f; IsDir = $false } })
            }
            [Windows.Forms.Clipboard]::SetText('清理一下')
            Copy-SelectedPath -List $one
            $txt = [Windows.Forms.Clipboard]::GetText()
            if ($txt -ne $f) { throw ('剪贴板是「' + $txt + '」，应该是整条路径「' + $f + '」') }

            # 多选：一行一条，两条都在
            $two = New-Object psobject -Property @{
                SelectedItems = @(
                    [pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f; IsDir = $false } },
                    [pscustomobject]@{ Tag = [pscustomobject]@{ Path = $f2; IsDir = $false } }
                )
            }
            Copy-SelectedPath -List $two
            $t2 = [Windows.Forms.Clipboard]::GetText()
            if (($t2 -ne ($f + "`r`n" + $f2)) -and ($t2 -ne ($f + "`n" + $f2))) {
                throw ('多选复制不对：' + $t2.Replace("`r", '\r').Replace("`n", '\n'))
            }
        } finally {
            try { [IO.File]::Delete($f) } catch { }
        }
    }

    Step '拖到自己所在分区：什么都不做' {
        $a = @(Get-ForeignPaths -Paths @('D:\a\x.txt') -Dir 'D:\a')
        if ($a.Count -ne 0) { throw '同目录的文件没被剔掉' }
        $b = @(Get-ForeignPaths -Paths @('D:\a\x.txt', 'D:\b\y.txt') -Dir 'D:\a\')
        if ($b.Count -ne 1) { throw ('没剔干净：剩 ' + $b.Count + ' 个') }
        $c = @(Get-ForeignPaths -Paths @('D:\a\x.txt') -Dir 'd:\A')
        if ($c.Count -ne 0) { throw '大小写不同的同一目录没被剔除' }

        # 没有按键按着时，ItemDrag 一律不许真的发起拖拽（这就是「点文件变成复制」的根）
        if (Test-CanStartListDrag) { throw '没按住左键却判定可以拖拽' }
    }

    Step '窗口层级：桌面之上、其它窗口之下' {
        $d = New-DefaultConfig
        if ($d.window.topmost) { throw '新装默认不该置顶（会压住其它程序的对话框）' }
        if ($d.window.zorder -ne 'desktop') { throw '默认 zorder 不是 desktop' }

        # 老配置（没有 zorder 字段、topmost=true）要自动降回桌面层，且只降一次
        $tmpOld = Join-Path $env:TEMP ('cfg_old_' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
        $keepPath = $script:ConfigPath
        try {
            $old = @'
{"title":"桌面框","sources":[],"window":{"x":100,"y":100,"width":520,"height":460,"topmost":true,"opacity":0.78,"locked":false},"view":{"showHidden":false,"iconSize":48}}
'@
            [IO.File]::WriteAllText($tmpOld, $old, (New-Object System.Text.UTF8Encoding($false)))
            $script:ConfigPath = $tmpOld
            $migrated = Read-Config
            if ($migrated.window.topmost) { throw '老配置没有迁移到桌面层' }

            # 已经带 zorder 的配置要原样尊重用户的选择
            $new = @'
{"title":"桌面框","sources":[],"window":{"x":100,"y":100,"width":520,"height":460,"topmost":true,"zorder":"top","opacity":0.78,"locked":false},"view":{"showHidden":false,"iconSize":48}}
'@
            [IO.File]::WriteAllText($tmpOld, $new, (New-Object System.Text.UTF8Encoding($false)))
            $kept = Read-Config
            if (-not $kept.window.topmost) { throw '显式选了置顶却被迁移掉了' }
        } finally {
            $script:ConfigPath = $keepPath
            try { [IO.File]::Delete($tmpOld) } catch { }
        }
    }

    # 撤掉自检临时加的那个来源，恢复到用户原本的样子（空就还是空）
    if ($selfTmpSource) {
        $script:Sources = @()
        $script:AppCfg.sources = @()
        try { Show-AllSources } catch { }
        $script:pnlEmpty.Visible = $true
        $script:lblStatus.Text = '等待添加目录'
        Update-Layout
        Write-Output ('       （已撤掉临时来源，回到「还没有分区」）')
    }

    Step '开机自动启动（Run 键写 / 读 / 删）' {
        # 用一个自检专用的值名，绝不碰用户真正的那条 DesktopBox
        $nm = 'DesktopBox_SelfCheck'
        try {
            Set-AutoStart -On $false -Name $nm | Out-Null
            if (Test-AutoStart -Name $nm) { throw '清理残留失败' }
            if (-not (Set-AutoStart -On $true -Name $nm)) { throw '写注册表失败' }
            if (-not (Test-AutoStart -Name $nm)) { throw '写了却读不到' }
            $v = Get-AutoStartValue -Name $nm
            if ($v -ne (Get-AutoStartCommand)) { throw ('命令不对：' + $v) }
            if ($v -notmatch '(desktop_box\.ps1|启动桌面框\.vbs)') { throw ('命令没指向本程序：' + $v) }
            Write-Output ('       ' + $v)
        } finally {
            Set-AutoStart -On $false -Name $nm | Out-Null
        }
        if (Test-AutoStart -Name $nm) { throw '取消勾选后注册表里还留着' }
        # 顺手确认自检没把用户那条真条目动坏
        Write-Output ('       用户实际自启 = ' + (Test-AutoStart))
    }

    Step 'Save-Config' { if (-not (Save-Config $script:AppCfg)) { throw 'save failed' } }
    Write-Output ('       in-memory window = ' + $script:AppCfg.window.width + 'x' + $script:AppCfg.window.height)
    if ($Debug) { Write-Output ([System.IO.File]::ReadAllText($script:ConfigPath)) }
    Step 'Config roundtrip' {
        $raw = [System.IO.File]::ReadAllText($script:ConfigPath)
        $back = $raw | ConvertFrom-Json
        foreach ($need in @('title', 'sources', 'window', 'view')) {
            if (-not $back.PSObject.Properties[$need]) { throw ('missing key: ' + $need) }
        }
        $inMemory = 0
        foreach ($s in @($script:AppCfg.sources)) { if ($s) { $inMemory++ } }
        $onDisk = 0
        foreach ($s in @($back.sources)) { if ($s) { $onDisk++ } }
        if ($onDisk -ne $inMemory) { throw ('sources lost: memory=' + $inMemory + ' disk=' + $onDisk) }
        if (-not ($back.window.width -is [int] -or $back.window.width -is [long])) { throw 'width not numeric' }
        Write-Output ('       (sources=' + $onDisk + ', window=' + $back.window.width + 'x' + $back.window.height + ')')
    }

    if ($null -ne $cfgBackup) {
        try { [System.IO.File]::WriteAllText($script:ConfigPath, $cfgBackup, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    }

    # 收尾：删掉自检用的临时配置，再确认真配置没被碰过
    try { if (Test-Path -LiteralPath $script:ConfigPath) { Remove-Item -LiteralPath $script:ConfigPath -Force } } catch { }
    if ($script:ConfigRealPath) {
        Write-Output ('       用户配置未改动 = ' + (Test-Path -LiteralPath $script:ConfigRealPath))
    }

    Write-Output ('SELFCHECK DONE failed=' + $script:SelfCheckFail)
    exit 0
}

try {
    [void][System.Windows.Forms.Application]::Run($form)
} catch {
    $msg = ($_ | Out-String)
    try {
        [IO.File]::WriteAllText($script:ErrorLog, $msg, (New-Object Text.UTF8Encoding($true)))
    } catch { }
    if ($Debug) {
        Write-Host $msg -ForegroundColor Red
        Write-Host ('错误详情已写入 ' + $script:ErrorLog) -ForegroundColor Yellow
    } else {
        [Windows.Forms.MessageBox]::Show(("桌面框启动失败：`r`n" + $_.Exception.Message + "`r`n`r`n详细信息见 error.log"), '桌面框', 'OK', 'Error') | Out-Null
    }
}
