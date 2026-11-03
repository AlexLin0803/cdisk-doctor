<#
  Classify.ps1 - C 盘文件迁移分析器
  ------------------------------------------------------------
  回答一个问题：C 盘上哪些东西可以直接搬到 D/E 盘？

  输出：
    1. 控制台摘要
    2. 迁移分析报告-<时间>.html
    3. Move-Plan-<时间>.ps1   （可直接执行的迁移脚本，含预览）

  用法:
    powershell -ExecutionPolicy Bypass -File Classify.ps1 [-MinMB 200] [-OpenReport]
#>
[CmdletBinding()]
param(
    [string]$Root = 'C:\',
    [int]$MinMB = 200,
    [string]$OutDir = $PSScriptRoot,
    [switch]$OpenReport
)

$ErrorActionPreference = 'SilentlyContinue'
if (-not $OutDir) { $OutDir = (Get-Location).Path }
$Version = '1.0'

# ---------------------------------------------------------------- 工具
function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}
function Esc {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;')
}

# ---------------------------------------------------------------- 分类
$UserExt = @('.mp4','.mkv','.avi','.mov','.wmv','.flv','.ts','.m4v','.webm','.rmvb','.mpg','.mpeg','.vob','.3gp','.m2ts',
             '.mp3','.flac','.wav','.aac','.m4a','.wma','.ape','.ogg','.dsf','.dff','.opus',
             '.jpg','.jpeg','.png','.gif','.bmp','.tif','.tiff','.webp','.heic','.raw','.cr2','.nef','.arw','.dng',
             '.pdf','.doc','.docx','.xls','.xlsx','.ppt','.pptx','.txt','.md','.csv','.rtf','.odt','.epub','.mobi',
             '.zip','.rar','.7z','.tar','.gz','.bz2','.xz','.iso','.cab',
             '.psd','.ai','.sketch','.fig','.blend','.max','.c4d','.aep','.prproj',
             '.vhd','.vhdx','.vmdk','.qcow2')
$InstallerExt = @('.exe','.msi','.msix','.appx','.msixbundle')

function Get-Zone([string]$p) {
    $x = $p.ToLower()
    if ($x.StartsWith('c:\windows')) { return 'Windows' }
    if ($x.StartsWith('c:\program files')) { return 'ProgramFiles' }
    if ($x.StartsWith('c:\programdata')) { return 'ProgramData' }
    if ($x.StartsWith('c:\users')) {
        if ($x -match '\\appdata\\local\\temp\\') { return 'Temp' }
        if ($x -match '\\appdata\\') { return 'AppData' }
        return 'UserHome'
    }
    if ($x.StartsWith('c:\$recycle.bin')) { return 'Recycle' }
    if ($x.StartsWith('c:\system volume information')) { return 'SystemVolume' }
    if ($x.StartsWith('c:\drvpath') -or $x.StartsWith('c:\recovery')) { return 'SystemVolume' }
    return 'Other'
}

function Get-Unit([string]$p) {
    if ($p -match '(?i)^[a-z]:\\Users\\[^\\]+\\AppData\\(Local|Roaming|LocalLow)\\([^\\]+)') { return $Matches[0] }
    if ($p -match '(?i)^[a-z]:\\Program Files( \(x86\))?\\[^\\]+') { return $Matches[0] }
    if ($p -match '(?i)^[a-z]:\\ProgramData\\[^\\]+') { return $Matches[0] }
    if ($p -match '(?i)^[a-z]:\\Windows') { return 'C:\Windows' }
    return (Split-Path $p -Parent)
}

# ---------------------------------------------------------------- 扫描
Write-Host ''
Write-Host '  Classify  ' -ForegroundColor Cyan -NoNewline
Write-Host "v$Version  -  C 盘迁移分析" -ForegroundColor Gray
Write-Host ('  ' + ('-' * 56)) -ForegroundColor DarkGray
Write-Host '  扫描中...' -ForegroundColor Yellow

$units = @{}
$bigFiles = New-Object System.Collections.ArrayList
$looseFiles = New-Object System.Collections.ArrayList
$bigBytes = [long]3MB
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stack = New-Object System.Collections.Stack
$stack.Push([System.IO.Path]::GetFullPath($Root))

while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try {
        $di = New-Object System.IO.DirectoryInfo $d
        foreach ($fi in $di.EnumerateFiles()) {
            try {
                $len = [long]$fi.Length
                $p = $fi.FullName
                $ext = $fi.Extension.ToLower()
                $u = Get-Unit $p
                if (-not $units.ContainsKey($u)) {
                    $units[$u] = [pscustomobject]@{ Path = $u; Bytes = [long]0; Count = [long]0; Zone = (Get-Zone $u); LastMod = [datetime]::MinValue }
                }
                $units[$u].Bytes += $len
                $units[$u].Count++
                if ($fi.LastWriteTime -gt $units[$u].LastMod) { $units[$u].LastMod = $fi.LastWriteTime }

                if ($len -ge $bigBytes) {
                    [void]$bigFiles.Add([pscustomobject]@{
                        Path = $p; Bytes = $len; Ext = $ext; Zone = (Get-Zone $p)
                        Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd')
                    })
                }
                # 散落在 C 盘根目录 / 非标准目录的下载类文件（排除缓存、更新包、运行时资源目录）
                if ($len -ge 20MB -and ($ext -in $UserExt) `
                    -and ($p -notmatch '(?i)\\windows|\\program files|\\programdata') `
                    -and ($p -notmatch '(?i)\\(cache|caches|update|updates|addons|dynamic_package|node_modules|installer|temp|resources|unziped|sdk_storage)\\')) {
                    [void]$looseFiles.Add([pscustomobject]@{
                        Path = $p; Bytes = $len; Ext = $ext; Unit = $u
                        Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd')
                    })
                }
            } catch {}
        }
    } catch {}
    try {
        $di2 = New-Object System.IO.DirectoryInfo $d
        foreach ($sub in $di2.EnumerateDirectories()) {
            try {
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                $stack.Push($sub.FullName)
            } catch {}
        }
    } catch {}
}

Write-Host ("  完成  {0:N0} 个目录单元 / {1:N0} 个大文件 / {2:N0}s" -f $units.Count, $bigFiles.Count, $sw.Elapsed.TotalSeconds) -ForegroundColor Green

# ---------------------------------------------------------------- 判定
$minBytes = [long]$MinMB * 1MB
$rows = New-Object System.Collections.ArrayList

foreach ($k in $units.Keys) {
    $u = $units[$k]
    if ($u.Bytes -lt $minBytes) { continue }
    if ($u.Zone -eq 'SystemVolume' -or $u.Zone -eq 'Recycle' -or $u.Zone -eq 'Temp') { continue }

    $name = Split-Path $u.Path -Leaf
    $kind = '个人文件'
    $action = '直接移动'
    $target = 'E:\MovedFiles'
    $note = ''

    switch ($u.Zone) {
        'Windows' { $kind = '系统'; $action = '不可迁移'; $target = '-'; $note = '删了系统会坏' }
        'ProgramFiles' {
            $kind = '程序'; $action = '卸载重装到 D 盘'; $target = 'D:\Program Files'
            $note = '直接搬会破坏注册表和快捷方式；用卸载+重装更稳'
        }
        'ProgramData' {
            $kind = '程序公共数据'; $action = '不建议迁移'; $target = '-'
            $note = '多程序共用，迁移容易出问题'
        }
        'AppData' {
            $kind = '应用数据'; $action = '整目录迁移 + 软链接'; $target = 'D:\MovedData'
            $note = '迁移前必须关闭对应程序'
        }
        'UserHome' {
            if ($name.StartsWith('.') -or $u.Path -match '(?i)^[a-z]:\\users\\[^\\]+\\.') {
                $kind = '开发工具数据'; $action = '整目录迁移 + 软链接'; $target = 'D:\MovedData'
                $note = '工具按绝对路径访问，需用软链接'
            } else { $kind = '用户目录'; $action = '直接移动'; $target = 'E:\MovedFiles' }
        }
        default { $kind = '其他'; $action = '直接移动'; $target = 'E:\MovedFiles' }
    }

    # 盘符根目录（pagefile / swapfile 等系统文件）不参与迁移
    if ($u.Path -match '^[A-Za-z]:\\$') { continue }

    # AppData 中这几类别动
    if ($u.Zone -eq 'AppData' -and $name -in @('Microsoft','Packages','Temp','Programs','Programs (x86)','LocalLow','ConnectedDevicesPlatform','Comms','Packages')) {
        $kind = '系统/应用框架'; $action = '不建议迁移'; $target = '-'
        $note = '系统组件或应用框架，迁移风险高'
    }

    [void]$rows.Add([pscustomobject]@{
        Path = $u.Path; Name = $name; Bytes = $u.Bytes; Count = $u.Count
        Zone = $u.Zone; Kind = $kind; Action = $action; Target = $target; Note = $note
        LastMod = $u.LastMod.ToString('yyyy-MM-dd')
    })
}

$rows = @($rows | Sort-Object -Property Bytes -Descending)

$movable = @($rows | Where-Object { $_.Action -eq '直接移动' })
$junction = @($rows | Where-Object { $_.Action -like '*软链接*' })
$reinstall = @($rows | Where-Object { $_.Action -like '*卸载重装*' })

$sumMove = ($movable | Measure-Object Bytes -Sum).Sum
$sumJunc = ($junction | Measure-Object Bytes -Sum).Sum
$sumReinst = ($reinstall | Measure-Object Bytes -Sum).Sum
if (-not $sumMove) { $sumMove = 0 }
if (-not $sumJunc) { $sumJunc = 0 }
if (-not $sumReinst) { $sumReinst = 0 }

$looseFiles = @($looseFiles | Sort-Object Bytes -Descending | Select-Object -First 60)
$sumLoose = ($looseFiles | Measure-Object Bytes -Sum).Sum
if (-not $sumLoose) { $sumLoose = 0 }

# ---------------------------------------------------------------- 生成迁移脚本
$plan = New-Object System.Text.StringBuilder
[void]$plan.AppendLine('# Move-Plan - 由 Classify.ps1 生成于 ' + (Get-Date).ToString('yyyy-MM-dd HH:mm'))
[void]$plan.AppendLine('# 用法: 先看一遍，确认无误后执行。所有命令都保留原目录结构。')
[void]$plan.AppendLine('')
[void]$plan.AppendLine('$ErrorActionPreference = ''Continue''')
[void]$plan.AppendLine('$DryRun = $true   # 改成 $false 才真正执行')
[void]$plan.AppendLine('')

[void]$plan.AppendLine('# ===== 1) 个人文件：直接移动 =====')
foreach ($m in $movable) {
    $leaf = $m.Name
    $dst = ('{0}\{1}' -f $m.Target, $leaf)
    [void]$plan.AppendLine(('Move-Folder "{0}" "{1}" {2}' -f $m.Path, $dst, (Format-Size $m.Bytes)))
}
[void]$plan.AppendLine('')
[void]$plan.AppendLine('# ===== 2) 应用数据：迁移 + junction =====')
foreach ($m in $junction) {
    [void]$plan.AppendLine(('# {0,-46} {1}' -f $m.Path, (Format-Size $m.Bytes)))
    [void]$plan.AppendLine(('Migrate-AppData "{0}" "D:\MovedData"' -f $m.Path))
}
[void]$plan.AppendLine('')
[void]$plan.AppendLine('# ===== 3) 程序：建议卸载后重装到 D 盘 =====')
foreach ($m in $reinstall) {
    [void]$plan.AppendLine(('# {0,-52} {1}' -f $m.Path, (Format-Size $m.Bytes)))
}
[void]$plan.AppendLine('')
[void]$plan.AppendLine(@'
function Move-Folder {
    param([string]$Src, [string]$Dst, [string]$Size)
    Write-Host ("  {0}  ->  {1}   ({2})" -f $Src, $Dst, $Size)
    if ($DryRun) { Write-Host '    [预览]' -ForegroundColor DarkGray; return }
    if (-not (Test-Path $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    $rc = (Start-Process robocopy -ArgumentList @("`"$Src`"", "`"$Dst`"", '/E', '/MOVE', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
    if ($rc -ge 8) { Write-Host "    失败 (robocopy $rc)" -ForegroundColor Red } else { Write-Host '    完成' -ForegroundColor Green }
}

function Migrate-AppData {
    param([string]$Src, [string]$TargetRoot)
    $leaf = Split-Path $Src -Leaf
    $dst = Join-Path $TargetRoot $leaf
    Write-Host ("  {0}  ->  {1}" -f $Src, $dst)
    if ($DryRun) { Write-Host '    [预览]' -ForegroundColor DarkGray; return }
    $rc = (Start-Process robocopy -ArgumentList @("`"$Src`"", "`"$dst`"", '/E', '/COPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
    if ($rc -ge 8) { Write-Host "    复制失败 (robocopy $rc)，源目录未动" -ForegroundColor Red; return }
    $bak = $Src + '.old'
    Rename-Item -LiteralPath $Src -NewName (Split-Path $bak -Leaf)
    cmd /c mklink /J "$Src" "$dst" | Out-Null
    Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host '    完成' -ForegroundColor Green
}
'@)

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$planPath = Join-Path $OutDir "Move-Plan-$stamp.ps1"
$enc = New-Object System.Text.UTF8Encoding $true
[System.IO.File]::WriteAllText($planPath, $plan.ToString(), $enc)

# ---------------------------------------------------------------- HTML
$usedPct = 0; $freeBytes = 0; $totalBytes = 0
$vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($vol) { $totalBytes = $vol.Size; $freeBytes = $vol.FreeSpace; $usedPct = [math]::Round(($vol.Size - $vol.FreeSpace) / $vol.Size * 100, 1) }

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">')
[void]$sb.AppendLine('<title>C 盘迁移分析</title><style>')
[void]$sb.AppendLine(@'
*{box-sizing:border-box}body{margin:0;background:#0f1216;color:#e6edf3;font:14px/1.65 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.wrap{max-width:1150px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:25px;margin:0 0 4px;font-weight:600}
.sub{color:#7d8896;font-size:13px;margin-bottom:26px}
h2{font-size:17px;margin:36px 0 10px;font-weight:600;color:#c9d6e3;border-left:3px solid #2f81f7;padding-left:10px}
h2 small{font-weight:400;color:#7d8896;font-size:13px;margin-left:8px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:13px}
.card{background:#161b22;border:1px solid #232b36;border-radius:10px;padding:15px 17px}
.card .k{font-size:12px;color:#7d8896}.card .v{font-size:24px;font-weight:600;margin-top:5px}
.card .v small{font-size:12px;color:#7d8896;font-weight:400;margin-left:3px}
.good .v{color:#3fb950}.warn .v{color:#d29922}.info .v{color:#2f81f7}.bad .v{color:#f85149}
table{width:100%;border-collapse:collapse;background:#161b22;border:1px solid #232b36;border-radius:10px;overflow:hidden;margin-top:6px}
th{text-align:left;font-size:12px;font-weight:600;color:#8b949e;background:#1c2330;padding:9px 11px;white-space:nowrap}
td{padding:8px 11px;border-top:1px solid #21282f;font-size:13px;vertical-align:top}
tr:hover td{background:#1a212b}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;font-weight:600}
.p{color:#7c8896;font-size:12px;word-break:break-all}
.tag{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11px;font-weight:600;white-space:nowrap}
.t-a{background:#0f2f1a;color:#3fb950;border:1px solid #1f6f34}
.t-b{background:#101e33;color:#58a6ff;border:1px solid #1f4b8f}
.t-c{background:#2e2410;color:#d29922;border:1px solid #6b4f10}
.t-d{background:#33110f;color:#f85149;border:1px solid #6e211c}
.note{background:#161b22;border:1px solid #232b36;border-left:3px solid #2f81f7;border-radius:6px;padding:12px 16px;margin:14px 0;font-size:13px;color:#a8b3c0}
code{background:#0d1117;border:1px solid #232b36;border-radius:4px;padding:1px 6px;font-size:12px;color:#79c0ff}
.bar{height:24px;border-radius:6px;overflow:hidden;display:flex;margin:20px 0 8px;background:#161b22}
.bar i{display:block;height:100%}
.legend{display:flex;gap:16px;font-size:12px;color:#7d8896;flex-wrap:wrap}
.dot{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:5px;vertical-align:middle}
footer{margin-top:46px;color:#586069;font-size:12px;text-align:center}
'@)
[void]$sb.AppendLine('</style></head><body><div class="wrap">')
[void]$sb.AppendLine('<h1>C 盘迁移分析</h1>')
[void]$sb.AppendLine(('<div class="sub">{0} &nbsp;|&nbsp; C 盘 {1:N0} GB，已用 {2}%，可用 {3:N2} GB</div>' -f (Get-Date).ToString('yyyy-MM-dd HH:mm'), ($totalBytes/1GB), $usedPct, ($freeBytes/1GB)))

[void]$sb.AppendLine('<div class="cards">')
[void]$sb.AppendLine(('<div class="card good"><div class="k">可直接搬走</div><div class="v">{0:N2}<small>GB</small></div></div>' -f ($sumMove/1GB)))
[void]$sb.AppendLine(('<div class="card info"><div class="k">迁移+软链接</div><div class="v">{0:N2}<small>GB</small></div></div>' -f ($sumJunc/1GB)))
[void]$sb.AppendLine(('<div class="card warn"><div class="k">卸载重装可省</div><div class="v">{0:N2}<small>GB</small></div></div>' -f ($sumReinst/1GB)))
[void]$sb.AppendLine(('<div class="card bad"><div class="k">不可迁移</div><div class="v">系统</div></div>'))
[void]$sb.AppendLine('</div>')

[void]$sb.AppendLine('<div class="note"><b>说明：</b>如果你的桌面 / 文档 / 下载已经重定向到其他盘，C 盘上可能几乎没有个人文件——占空间的主要是<b>应用数据（AppData）</b>和<b>程序本体</b>。这两类不能像普通文件那样直接剪切，必须用「整目录迁移 + 软链接」或「卸载后重装」。</div>')

$usedGB = ($totalBytes - $freeBytes) / 1GB
$pMove = if ($usedGB -gt 0) { [math]::Round(($sumMove/1GB) / $usedGB * 100, 1) } else { 0 }
$pJunc = if ($usedGB -gt 0) { [math]::Round(($sumJunc/1GB) / $usedGB * 100, 1) } else { 0 }
$pRein = if ($usedGB -gt 0) { [math]::Round(($sumReinst/1GB) / $usedGB * 100, 1) } else { 0 }
[void]$sb.AppendLine(('<div class="bar"><i style="width:{0}%;background:#3fb950"></i><i style="width:{1}%;background:#2f81f7"></i><i style="width:{2}%;background:#d29922"></i><i style="width:{3}%;background:#30363d"></i></div>' -f $pMove, $pJunc, $pRein, [math]::Max(0, 100 - $pMove - $pJunc - $pRein)))
[void]$sb.AppendLine(('<div class="legend"><span><span class="dot" style="background:#3fb950"></span>可直接搬 {0:N2} GB</span><span><span class="dot" style="background:#2f81f7"></span>迁移+软链接 {1:N2} GB</span><span><span class="dot" style="background:#d29922"></span>卸载重装 {2:N2} GB</span><span><span class="dot" style="background:#30363d"></span>不可动</span></div>' -f ($sumMove/1GB), ($sumJunc/1GB), ($sumReinst/1GB)))

# 表 1 可直接移动
[void]$sb.AppendLine(('<h2>A. 可以直接搬走的<small>{0:N2} GB / {1} 项</small></h2>' -f ($sumMove/1GB), $movable.Count))
if ($movable.Count -eq 0) {
    [void]$sb.AppendLine('<div class="note">没有发现体积超过阈值的独立个人文件目录。</div>')
} else {
    [void]$sb.AppendLine('<table><tr><th>目录</th><th class="num">大小</th><th class="num">文件数</th><th>建议放</th></tr>')
    foreach ($m in $movable) {
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="num">{2:N0}</td><td class="p">{3}</td></tr>' -f (Esc $m.Path), (Format-Size $m.Bytes), $m.Count, (Esc $m.Target)))
    }
    [void]$sb.AppendLine('</table>')
}

# 表 2 应用数据
[void]$sb.AppendLine(('<h2>B. 应用数据（整目录迁移 + 软链接）<small>{0:N2} GB / {1} 项</small></h2>' -f ($sumJunc/1GB), $junction.Count))
[void]$sb.AppendLine('<div class="note">做法：把目录搬到 D 盘，原位置留一个 junction。程序照常按原路径读写，感觉不到变化。迁移前必须<b>关闭对应程序</b>。</div>')
[void]$sb.AppendLine('<table><tr><th>目录</th><th class="num">大小</th><th class="num">文件数</th><th>建议放</th><th>备注</th></tr>')
foreach ($m in $junction) {
    [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="num">{2:N0}</td><td class="p">{3}</td><td class="p">{4}</td></tr>' -f (Esc $m.Path), (Format-Size $m.Bytes), $m.Count, (Esc $m.Target), (Esc $m.Note)))
}
[void]$sb.AppendLine('</table>')

# 表 3 程序
if ($reinstall.Count -gt 0) {
    [void]$sb.AppendLine(('<h2>C. 程序本体（建议卸载后重装到 D 盘）<small>{0:N2} GB</small></h2>' -f ($sumReinst/1GB)))
    [void]$sb.AppendLine('<table><tr><th>目录</th><th class="num">大小</th><th class="num">文件数</th></tr>')
    foreach ($m in $reinstall) {
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="num">{2:N0}</td></tr>' -f (Esc $m.Path), (Format-Size $m.Bytes), $m.Count))
    }
    [void]$sb.AppendLine('</table>')
}

# 表 4 散落/下载文件
if ($looseFiles.Count -gt 0) {
    [void]$sb.AppendLine(('<h2>D. 散落的大文件（疑似下载/安装包）<small>{0:N2} GB</small></h2>' -f ($sumLoose/1GB)))
    [void]$sb.AppendLine('<div class="note">这些是散落在系统目录之外的大文件。如果已经装过/看过了，可以直接删；想留着就搬到 E 盘。</div>')
    [void]$sb.AppendLine('<table><tr><th>文件</th><th class="num">大小</th><th class="num">修改日期</th></tr>')
    foreach ($m in $looseFiles) {
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="num p">{2}</td></tr>' -f (Esc $m.Path), (Format-Size $m.Bytes), $m.Modified))
    }
    [void]$sb.AppendLine('</table>')
}

[void]$sb.AppendLine(('<div class="note">迁移脚本已生成：<code>{0}</code> —— 默认 <code>$DryRun = $true</code>，先跑一遍看清单，改成 <code>$false</code> 才真正执行。</div>' -f (Esc (Split-Path $planPath -Leaf))))
[void]$sb.AppendLine(('<footer>Classify v{0} · 本机生成，未上传任何数据</footer>' -f $Version))
[void]$sb.AppendLine('</div></body></html>')

$htmlPath = Join-Path $OutDir "迁移分析-$stamp.html"
[System.IO.File]::WriteAllText($htmlPath, $sb.ToString(), $enc)

# ---------------------------------------------------------------- 控制台
Write-Host ''
Write-Host ('  A. 可以直接搬走:      {0:N2} GB  ({1} 项)' -f ($sumMove/1GB), $movable.Count) -ForegroundColor Green
$movable | Select-Object -First 8 | ForEach-Object { Write-Host ('     {0,-58} {1,9}' -f $_.Name, (Format-Size $_.Bytes)) -ForegroundColor Gray }

Write-Host ''
Write-Host ('  B. 迁移+软链接:       {0:N2} GB  ({1} 项)' -f ($sumJunc/1GB), $junction.Count) -ForegroundColor Cyan
$junction | Select-Object -First 8 | ForEach-Object { Write-Host ('     {0,-58} {1,9}' -f $_.Name, (Format-Size $_.Bytes)) -ForegroundColor Gray }

Write-Host ''
Write-Host ('  C. 卸载重装可省:      {0:N2} GB  ({1} 项)' -f ($sumReinst/1GB), $reinstall.Count) -ForegroundColor Yellow

Write-Host ''
Write-Host ('  D. 散落大文件:        {0:N2} GB' -f ($sumLoose/1GB)) -ForegroundColor Yellow

Write-Host ''
Write-Host ('  报告: ' + $htmlPath) -ForegroundColor Cyan
Write-Host ('  迁移脚本: ' + $planPath) -ForegroundColor Cyan
if ($OpenReport) { Start-Process $htmlPath }