<#
  CDiskDoctor - C 盘空间诊断 / 清理 / 迁移工具
  ---------------------------------------------------------------
  用法:
    # 1) 只分析，生成 HTML 报告（默认，不做任何修改）
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Analyze -OpenReport

    # 2) 预览清理（不删任何东西）
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Clean -DryRun

    # 3) 真正清理（只清 Safe 类，默认跳过 2 天内修改过的文件）
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Clean -Apply

    # 4) 清理指定类别（可加 Caution 类）
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Clean -Apply -Categories AppCache,Prefetch

    # 5) 迁移大目录到别的盘并建立软链接（会先复制校验，成功后删源）
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Migrate -Path "C:\Users\<用户名>\AppData\Roaming\kingsoft" -Target "D:\MovedData" -Apply
    powershell -ExecutionPolicy Bypass -File CDiskDoctor.ps1 -Mode Migrate -Rollback "C:\Users\<用户名>\AppData\Roaming\kingsoft"

  安全说明:
    * Analyze 模式纯只读。
    * Clean 模式只作用于内置白名单路径，不会碰用户文档、桌面、下载。
    * Migrate 使用 robocopy 复制 + 校验，成功后才删除源目录，并留下 junction 软链接。
#>
[CmdletBinding()]
param(
    [ValidateSet('Analyze', 'Clean', 'Migrate', 'System', 'Help')]
    [string]$Mode = 'Analyze',

    [string]$Root = 'C:\',
    [string]$OutDir = $PSScriptRoot,

    # Clean
    [switch]$Apply,
    [switch]$DryRun,
    [string[]]$Categories,
    [int]$TempAgeDays = 2,
    [switch]$Force,

    # Migrate
    [string]$Path,
    [string]$Target,
    [string]$Rollback,

    # Analyze
    [switch]$OpenReport,
    [switch]$UseCache
)

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'

if (-not $OutDir) { $OutDir = (Get-Location).Path }
$Version = '1.1'

# 允许 -Categories TempUser,EdgeCache 通过 powershell -File 调用（会被当成单个字符串）
if ($Categories) {
    $Categories = @($Categories | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

# ============================================================
#  通用函数
# ============================================================

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Esc {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return '' }
    return $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

# 大小写不敏感、跳过 reparse point 的目录树遍历
function Measure-Tree {
    param([string]$Path, [string]$Include = $null)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Bytes = 0; Files = 0 }
    }
    $item = Get-Item -LiteralPath $Path -Force
    # 软链接/junction 指向别的盘时，不计入本盘占用
    if ($item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return [pscustomobject]@{ Bytes = 0; Files = 0 }
    }
    if (-not $item.PSIsContainer) {
        return [pscustomobject]@{ Bytes = [long]$item.Length; Files = 1 }
    }

    $bytes = [long]0
    $files = [long]0
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)

    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            if ($Include) {
                foreach ($fi in $di.EnumerateFiles($Include)) {
                    try { $bytes += $fi.Length; $files++ } catch {}
                }
            } else {
                foreach ($fi in $di.EnumerateFiles()) {
                    try { $bytes += $fi.Length; $files++ } catch {}
                }
            }
        } catch {}
        if (-not $Include) {
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
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

# ============================================================
#  全盘扫描（一次遍历拿到：目录大小、文件数、最大文件）
# ============================================================
function Invoke-Scan {
    param([string]$ScanRoot, [int]$BigFileMB = 200)

    $rootFull = [System.IO.Path]::GetFullPath($ScanRoot)
    $bigBytes = [long]$BigFileMB * 1MB

    $own = @{}
    $cnt = @{}
    $parent = @{}
    $bigFiles = New-Object System.Collections.ArrayList

    $fileTotal = [long]0
    $fileCount = [long]0

    $stack = New-Object System.Collections.Stack
    $stack.Push($rootFull)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $sum = [long]0
        $c = 0
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($fi in $di.EnumerateFiles()) {
                try {
                    $sum += $fi.Length
                    $c++
                    if ($fi.Length -ge $bigBytes) {
                        [void]$bigFiles.Add([pscustomobject]@{
                            Path = $fi.FullName
                            Bytes = $fi.Length
                            Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd')
                        })
                    }
                } catch {}
            }
        } catch {}

        $own[$d] = $sum
        $cnt[$d] = $c
        $fileTotal += $sum
        $fileCount += $c

        try {
            $di2 = New-Object System.IO.DirectoryInfo $d
            foreach ($sub in $di2.EnumerateDirectories()) {
                try {
                    if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $p = $sub.FullName
                    $parent[$p] = $d
                    $stack.Push($p)
                } catch {}
            }
        } catch {}
    }

    # 自底向上汇总（按路径长度倒序，保证父目录最后累加）
    $total = @{}
    foreach ($k in $own.Keys) { $total[$k] = $own[$k] }
    $keys = @($total.Keys)
    $keys = @($keys | Sort-Object -Property Length -Descending)
    foreach ($k in $keys) {
        if ($parent.ContainsKey($k)) {
            $pk = $parent[$k]
            if ($total.ContainsKey($pk)) { $total[$pk] = [long]$total[$pk] + [long]$total[$k] }
        }
    }

    return [pscustomobject]@{
        Root      = $rootFull
        Bytes     = $fileTotal
        Files     = $fileCount
        Dirs      = $own.Count
        Elapsed   = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        ByDir     = $total
        DirFiles  = $cnt
        BigFiles  = $bigFiles
    }
}

# ============================================================
#  清理规则
# ============================================================
function Get-Rules {
    $R = @()
    $L = $env:LOCALAPPDATA
    $A = $env:APPDATA
    $W = $env:WINDIR
    $PD = $env:ProgramData

    # ---------- Safe：可以无脑清 ----------
    $R += @{ Id = 'TempUser'; Name = '用户临时文件'; Risk = 'Safe'; Age = $TempAgeDays
        Desc = '各类程序运行时产生的临时文件，关机后大多无用'
        Paths = @("$L\Temp") }

    $R += @{ Id = 'TempWindows'; Name = '系统临时文件'; Risk = 'Safe'; Age = $TempAgeDays
        Desc = 'Windows 与安装程序留下的临时文件'
        Paths = @("$W\Temp") }

    $R += @{ Id = 'CrashDump'; Name = '崩溃转储与错误报告'; Risk = 'Safe'; Age = 0
        Desc = '程序崩溃时的内存转储，普通用户不需要'
        Paths = @("$W\Minidump", "$W\LiveKernelReports", "$W\memory.dmp",
                  "$L\CrashDumps",
                  "$PD\Microsoft\Windows\WER\ReportQueue",
                  "$PD\Microsoft\Windows\WER\ReportArchive",
                  "$PD\Microsoft\Windows\WER\Temp") }

    $R += @{ Id = 'WinLogs'; Name = '系统与安装日志'; Risk = 'Safe'; Age = 0
        Desc = 'Windows 日志、CBS 日志、驱动安装日志'
        Paths = @("$W\Logs", "$W\System32\LogFiles", "$W\Panther",
                  "$W\System32\winevt\Logs\*.evtx") }

    $R += @{ Id = 'UpdateCache'; Name = 'Windows 更新下载缓存'; Risk = 'Safe'; Age = 0
        Desc = '已安装更新的安装包残留，删掉不影响已装好的更新'
        Paths = @("$W\SoftwareDistribution\Download",
                  "$W\SoftwareDistribution\DeliveryOptimization") }

    $R += @{ Id = 'ThumbCache'; Name = '缩略图与图标缓存'; Risk = 'Safe'; Age = 0
        Desc = '资源管理器生成的缩略图数据库，会自动重建'
        Paths = @("$L\Microsoft\Windows\Explorer")
        Include = 'thumbcache_*.db' }
    $R += @{ Id = 'IconCache'; Name = '图标缓存'; Risk = 'Safe'; Age = 0
        Desc = '资源管理器图标缓存，会自动重建'
        Paths = @("$L\Microsoft\Windows\Explorer")
        Include = 'iconcache_*.db' }

    $R += @{ Id = 'UpdaterFiles'; Name = '各软件更新安装包残留'; Risk = 'Safe'; Age = 0
        Desc = '各种应用下载完却没删的安装包（几百 MB 很常见）'
        Paths = @("$L\*-updater",
                  "$A\LarkShell\update\update_downloading",
                  "$L\QuarkCloudDrive\User Data\updates") }

    $R += @{ Id = 'EdgeCache'; Name = 'Edge 浏览器缓存'; Risk = 'Safe'; Age = 0
        Desc = '网页缓存，清理后首次打开网页略慢，不影响登录状态'
        Paths = @("$L\Microsoft\Edge\User Data\*\Cache",
                  "$L\Microsoft\Edge\User Data\*\Code Cache",
                  "$L\Microsoft\Edge\User Data\*\GPUCache",
                  "$L\Microsoft\Edge\User Data\*\Service Worker\CacheStorage") }

    $R += @{ Id = 'ChromeCache'; Name = 'Chrome 浏览器缓存'; Risk = 'Safe'; Age = 0
        Desc = '网页缓存，清理后首次打开网页略慢'
        Paths = @("$L\Google\Chrome\User Data\*\Cache",
                  "$L\Google\Chrome\User Data\*\Code Cache",
                  "$L\Google\Chrome\User Data\*\GPUCache",
                  "$L\Google\Chrome\User Data\*\Service Worker\CacheStorage") }

    $R += @{ Id = 'RecycleBin'; Name = '回收站'; Risk = 'Safe'; Age = 0; Special = 'Recycle'
        Desc = 'C 盘回收站里已删除但未清空的文件'
        Paths = @('C:\$Recycle.Bin') }

    # ---------- Caution：能清，但先确认 ----------
    $R += @{ Id = 'AppCache'; Name = '应用缓存（剪映/飞书/WPS/微信等）'; Risk = 'Caution'; Age = 0
        Desc = '各 App 的缓存目录。清理后 App 需重新加载资源，不影响账号与文件'
        AutoCache = $true
        Hints = @('Cache', 'cache', 'Caches', 'caches', 'GPUCache', 'Code Cache',
                  'CacheStorage', 'blob_storage', 'Crashpad', 'crashpad',
                  'Temp', 'temp', 'Log', 'logs') }

    $R += @{ Id = 'DevCache'; Name = '开发工具缓存'; Risk = 'Caution'; Age = 0
        Desc = 'npm/pnpm/pip/uv 等包管理器缓存，删了下次安装会重新下载'
        Paths = @("$L\npm-cache", "$L\pnpm\store", "$L\pip\cache",
                  "$L\uv\cache", "$A\npm-cache", "$env:USERPROFILE\.cache\pip") }

    $R += @{ Id = 'Prefetch'; Name = '预读取数据'; Risk = 'Caution'; Age = 0
        Desc = '加快程序启动的预读取文件，删除后前几次启动会略慢'
        Paths = @("$W\Prefetch") }

    $R += @{ Id = 'SearchIndex'; Name = 'Windows 搜索索引'; Risk = 'Caution'; Age = 0
        Desc = 'Windows.edb 搜索索引，删除后需要重建，搜索会短暂变慢'
        Paths = @("$PD\Microsoft\Search\Data\Applications\Windows") }

    # ---------- Danger：只报告，不建议随便动 ----------
    $R += @{ Id = 'WinSxS'; Name = 'WinSxS 组件存储'; Risk = 'Danger'; Age = 0
        Desc = '系统组件库。只能用 DISM 官方清理，不能手动删'
        Paths = @("$W\WinSxS")
        Hint = '运行: Dism /Online /Cleanup-Image /StartComponentCleanup /ResetBase' }

    $R += @{ Id = 'WindowsOld'; Name = '旧系统备份 (Windows.old)'; Risk = 'Danger'; Age = 0
        Desc = '升级前的旧系统，确认不回滚后可删'
        Paths = @((Join-Path $Root 'Windows.old')) }

    return $R
}

function Expand-RulePaths {
    param($Rule)
    $out = @()
    $seen = @{}
    foreach ($p in $Rule.Paths) {
        if ($p -match '[\*\?]') {
            $hits = @(Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue)
            foreach ($m in $hits) {
                if ($seen.ContainsKey($m.FullName)) { continue }
                $seen[$m.FullName] = 1
                $out += $m.FullName
            }
        } elseif (Test-Path -LiteralPath $p) {
            if ($seen.ContainsKey($p)) { continue }
            $seen[$p] = 1
            $out += $p
        }
    }
    return $out
}

function Measure-Rule {
    param($Rule, $Scan)
    $bytes = [long]0
    $files = [long]0
    $paths = @()
    $exists = $false

    if ($Rule.Special -eq 'Recycle') {
        foreach ($p in $Rule.Paths) {
            if (Test-Path -LiteralPath $p) {
                $exists = $true
                $m = Measure-Tree -Path $p
                $bytes += $m.Bytes
                $files += $m.Files
                $paths += $p
            }
        }
        return [pscustomobject]@{ Bytes = $bytes; Files = $files; Paths = $paths; Exists = $exists }
    }

    if ($Rule.AutoCache) {
        $seen = @{}
        foreach ($big in $Rule.CacheScanPaths) {
            if (-not (Test-Path -LiteralPath $big)) { continue }
            # 已迁移到其他盘的软链接目录，不再计入本盘
            $bi = Get-Item -LiteralPath $big -Force
            if ($bi.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }
            $dirs = New-Object System.Collections.ArrayList
            [void]$dirs.Add($big)
            foreach ($c1 in @(Get-ChildItem -LiteralPath $big -Directory -Force -ErrorAction SilentlyContinue)) {
                [void]$dirs.Add($c1.FullName)
                foreach ($c2 in @(Get-ChildItem -LiteralPath $c1.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                    [void]$dirs.Add($c2.FullName)
                }
            }
            foreach ($cand in $dirs) {
                $leaf = Split-Path $cand -Leaf
                if ($Rule.Hints -notcontains $leaf) { continue }
                # 跳过被其他命中目录包含的子目录，避免重复计数
                $nested = $false
                foreach ($k in $seen.Keys) {
                    if ($cand.StartsWith($k + '\')) { $nested = $true; break }
                }
                if ($nested) { continue }
                $seen[$cand] = 1
                if ($Scan -and $Scan.ByDir.ContainsKey($cand)) {
                    $bytes += [long]$Scan.ByDir[$cand]
                    $files += [long]$Scan.DirFiles[$cand]
                } else {
                    $m = Measure-Tree -Path $cand
                    $bytes += $m.Bytes; $files += $m.Files
                }
                $paths += $cand
                $exists = $true
            }
        }
        return [pscustomobject]@{ Bytes = $bytes; Files = $files; Paths = $paths; Exists = $exists }
    }

    foreach ($p in (Expand-RulePaths -Rule $Rule)) {
        $exists = $true
        if ($Rule.Include) {
            $m = Measure-Tree -Path $p -Include $Rule.Include
            $bytes += $m.Bytes; $files += $m.Files
        } elseif ($Scan.ByDir -and $Scan.ByDir.ContainsKey($p)) {
            $bytes += [long]$Scan.ByDir[$p]
            $files += [long]$Scan.DirFiles[$p]
        } else {
            $m = Measure-Tree -Path $p
            $bytes += $m.Bytes; $files += $m.Files
        }
        $paths += $p
    }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Paths = $paths; Exists = $exists }
}

# ============================================================
#  删除引擎
# ============================================================
function Remove-Junk {
    param(
        [string]$Path,
        [string]$Include,
        [int]$AgeDays = 0,
        [switch]$ForceDelete,
        [System.Collections.ArrayList]$Log
    )
    $freed = [long]0
    $deleted = 0
    $failed = 0
    $skipped = 0

    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Freed = 0; Deleted = 0; Failed = 0; Skipped = 0 } }
    $item = Get-Item -LiteralPath $Path -Force
    $cutoff = (Get-Date).AddDays(-$AgeDays)

    if (-not $item.PSIsContainer) {
        try {
            if (-not $ForceDelete -and $item.LastWriteTime -gt $cutoff) { return [pscustomobject]@{ Freed = 0; Deleted = 0; Failed = 0; Skipped = 1 } }
            $len = [long]$item.Length
            $item.Attributes = 'Normal'
            [System.IO.File]::Delete($item.FullName)
            $freed += $len; $deleted++
        } catch { $failed++ }
        return [pscustomobject]@{ Freed = $freed; Deleted = $deleted; Failed = $failed; Skipped = 0 }
    }

    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    $dirsToTry = New-Object System.Collections.ArrayList

    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            if ($Include) {
                foreach ($fi in $di.EnumerateFiles($Include)) {
                    try {
                        if (-not $ForceDelete -and $fi.LastWriteTime -gt $cutoff) { $skipped++; continue }
                        $len = [long]$fi.Length
                        $fi.Attributes = [System.IO.FileAttributes]::Normal
                        [System.IO.File]::Delete($fi.FullName)
                        $freed += $len; $deleted++
                    } catch { $failed++ }
                }
            } else {
                foreach ($fi in $di.EnumerateFiles()) {
                    try {
                        if (-not $ForceDelete -and $fi.LastWriteTime -gt $cutoff) { $skipped++; continue }
                        $len = [long]$fi.Length
                        $fi.Attributes = [System.IO.FileAttributes]::Normal
                        [System.IO.File]::Delete($fi.FullName)
                        $freed += $len; $deleted++
                    } catch { $failed++ }
                }
            }
        } catch {}
        try {
            $di2 = New-Object System.IO.DirectoryInfo $d
            foreach ($sub in $di2.EnumerateDirectories()) {
                try {
                    if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    $stack.Push($sub.FullName)
                    [void]$dirsToTry.Add($sub.FullName)
                } catch {}
            }
        } catch {}
    }

    # 尝试删除已空的子目录（由深到浅）
    foreach ($dd in ($dirsToTry | Sort-Object -Property Length -Descending)) {
        try {
            if (-not (Get-ChildItem -LiteralPath $dd -Force -ErrorAction SilentlyContinue)) {
                [System.IO.Directory]::Delete($dd, $false)
            }
        } catch {}
    }
    try {
        if (-not $Include -and -not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            # 保留规则根目录本身（很多程序要求目录存在）
        }
    } catch {}

    if ($Log) { [void]$Log.Add(('{0,-12} {1,-60} 释放 {2,10}  删除 {3,5}  失败 {4,3}  跳过 {5,3}' -f '', $Path, (Format-Size $freed), $deleted, $failed, $skipped)) }
    return [pscustomobject]@{ Freed = $freed; Deleted = $deleted; Failed = $failed; Skipped = $skipped }
}

# ============================================================
#  HTML 报告
# ============================================================
function New-Report {
    param($Data, [string]$FilePath)

    $d = $Data
    $usedPct = [math]::Round(($d.DiskTotal - $d.DiskFree) / $d.DiskTotal * 100, 1)
    $freePct = 100 - $usedPct

    $safeBytes = 0; $cautionBytes = 0
    foreach ($r in $d.Rules) {
        if ($r.Risk -eq 'Safe') { $safeBytes += $r.Bytes }
        elseif ($r.Risk -eq 'Caution') { $cautionBytes += $r.Bytes }
    }

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine('<!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">')
    [void]$sb.AppendLine('<meta name="viewport" content="width=device-width,initial-scale=1">')
    [void]$sb.AppendLine('<title>C 盘空间诊断报告</title><style>')
    [void]$sb.AppendLine(@'
*{box-sizing:border-box}
body{margin:0;background:#0f1216;color:#e6edf3;font:14px/1.6 -apple-system,"Segoe UI","Microsoft YaHei",sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:32px 20px 80px}
h1{font-size:26px;margin:0 0 4px;font-weight:600}
h2{font-size:17px;margin:38px 0 12px;font-weight:600;color:#c9d6e3;border-left:3px solid #2f81f7;padding-left:10px}
.sub{color:#7d8896;font-size:13px;margin-bottom:28px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(200px,1fr));gap:14px}
.card{background:#161b22;border:1px solid #232b36;border-radius:10px;padding:16px 18px}
.card .k{font-size:12px;color:#7d8896;letter-spacing:.4px}
.card .v{font-size:26px;font-weight:600;margin-top:6px}
.card .v small{font-size:13px;color:#7d8896;font-weight:400;margin-left:4px}
.good .v{color:#3fb950}.warn .v{color:#d29922}.bad .v{color:#f85149}.info .v{color:#2f81f7}
.bar{height:26px;border-radius:6px;overflow:hidden;display:flex;margin:22px 0 8px;background:#161b22}
.bar i{display:block;height:100%}
.bar .u{background:linear-gradient(90deg,#f85149,#d29922)}
.bar .f{background:linear-gradient(90deg,#2ea043,#3fb950)}
.legend{display:flex;gap:18px;font-size:12px;color:#7d8896}
.dot{display:inline-block;width:9px;height:9px;border-radius:2px;margin-right:6px;vertical-align:middle}
table{width:100%;border-collapse:collapse;background:#161b22;border:1px solid #232b36;border-radius:10px;overflow:hidden}
th{text-align:left;font-size:12px;font-weight:600;color:#8b949e;background:#1c2330;padding:10px 12px;white-space:nowrap}
td{padding:9px 12px;border-top:1px solid #21282f;vertical-align:middle;font-size:13px}
tr:hover td{background:#1a212b}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;font-weight:600}
.p{color:#6e7a89;font-size:12px;word-break:break-all}
.mini{height:6px;background:#232b36;border-radius:3px;overflow:hidden;min-width:70px;margin-top:4px}
.mini i{display:block;height:100%;background:#2f81f7}
.tag{display:inline-block;padding:1px 8px;border-radius:20px;font-size:11px;font-weight:600}
.t-safe{background:#0f2f1a;color:#3fb950;border:1px solid #1f6f34}
.t-caution{background:#2e2410;color:#d29922;border:1px solid #6b4f10}
.t-danger{background:#33110f;color:#f85149;border:1px solid #6e211c}
.note{background:#161b22;border:1px solid #232b36;border-left:3px solid #2f81f7;border-radius:6px;padding:12px 16px;margin:14px 0;font-size:13px;color:#a8b3c0}
code{background:#0d1117;border:1px solid #232b36;border-radius:4px;padding:1px 6px;font-size:12px;color:#79c0ff}
footer{margin-top:50px;color:#586069;font-size:12px;text-align:center}
'@)
    [void]$sb.AppendLine('</style></head><body><div class="wrap">')

    [void]$sb.AppendLine('<h1>C 盘空间诊断报告</h1>')
    [void]$sb.AppendLine(('<div class="sub">{0} &nbsp;|&nbsp; 扫描 {1:N0} 个文件 / {2:N0} 个目录，耗时 {3}s &nbsp;|&nbsp; CDiskDoctor v{4}</div>' -f $d.When, $d.Files, $d.Dirs, $d.Elapsed, $Version))

    # 概览
    [void]$sb.AppendLine('<div class="cards">')
    [void]$sb.AppendLine(('<div class="card info"><div class="k">C 盘容量</div><div class="v">{0:N1}<small>GB</small></div></div>' -f ($d.DiskTotal/1GB)))
    [void]$sb.AppendLine(('<div class="card {0}"><div class="k">剩余空间</div><div class="v">{1:N2}<small>GB</small></div></div>' -f $(if ($freePct -lt 10) {'bad'} else {'good'}), ($d.DiskFree/1GB)))
    [void]$sb.AppendLine(('<div class="card good"><div class="k">可安全清理</div><div class="v">{0:N2}<small>GB</small></div></div>' -f ($safeBytes/1GB)))
    [void]$sb.AppendLine(('<div class="card warn"><div class="k">需确认后清理</div><div class="v">{0:N2}<small>GB</small></div></div>' -f ($cautionBytes/1GB)))
    [void]$sb.AppendLine('</div>')

    [void]$sb.AppendLine(('<div class="bar"><i class="u" style="width:{0}%"></i><i class="f" style="width:{1}%"></i></div>' -f $usedPct, $freePct))
    [void]$sb.AppendLine(('<div class="legend"><span><span class="dot" style="background:#f85149"></span>已用 {0:N1} GB ({1}%)</span><span><span class="dot" style="background:#3fb950"></span>可用 {2:N2} GB ({3}%)</span></div>' -f (($d.DiskTotal-$d.DiskFree)/1GB), $usedPct, ($d.DiskFree/1GB), $freePct))

    if ($freePct -lt 5) {
        [void]$sb.AppendLine('<div class="note"><b>空间告急：</b>剩余不足 5%，Windows 更新、页面文件和临时文件写入都可能失败，建议先把下面的「可安全清理」执行掉。</div>')
    }

    # 系统级占用（页面文件 / 休眠文件等）
    if ($d.SystemUsage -and $d.SystemUsage.Count -gt 0) {
        [void]$sb.AppendLine('<h2>系统级占用（普通清理看不到）</h2>')
        [void]$sb.AppendLine('<div class="note">这些文件不是垃圾，但放错盘会白占几个甚至十几个 GB。用 <code>-Mode System</code> 检查，<code>-Mode System -Apply</code> 可把页面文件迁出 C 盘。</div>')
        [void]$sb.AppendLine('<table><tr><th>项目</th><th class="num">占用</th><th>状态</th><th>说明</th></tr>')
        foreach ($s in $d.SystemUsage) {
            $cls = 't-safe'; $label = '正常'
            if ($s.Severity -eq 'warn') { $cls = 't-caution'; $label = '可优化' }
            if ($s.Severity -eq 'bad') { $cls = 't-danger'; $label = '浪费空间' }
            [void]$sb.AppendLine(('<tr><td><b>{0}</b></td><td class="num">{1}</td><td><span class="tag {2}">{3}</span></td><td class="p">{4}</td></tr>' -f (Esc $s.Name), (Format-Size $s.Bytes), $cls, $label, (Esc $s.Advice)))
        }
        [void]$sb.AppendLine('</table>')
    }

    # 清理清单
    [void]$sb.AppendLine('<h2>可清理项目</h2>')
    [void]$sb.AppendLine('<table><tr><th>类别</th><th>风险</th><th class="num">占用</th><th class="num">文件数</th><th>说明</th></tr>')
    foreach ($r in ($d.Rules | Sort-Object -Property Bytes -Descending)) {
        if ($r.Bytes -le 0) { continue }
        $cls = 't-safe'; $label = '安全'
        if ($r.Risk -eq 'Caution') { $cls = 't-caution'; $label = '需确认' }
        if ($r.Risk -eq 'Danger') { $cls = 't-danger'; $label = '不要手删' }
        [void]$sb.AppendLine(('<tr><td><b>{0}</b></td><td><span class="tag {1}">{2}</span></td><td class="num">{3}</td><td class="num">{4:N0}</td><td class="p">{5}</td></tr>' -f (Esc $r.Name), $cls, $label, (Format-Size $r.Bytes), $r.Files, (Esc $r.Desc)))
    }
    [void]$sb.AppendLine('</table>')

    # 目录
    [void]$sb.AppendLine('<h2>占用最大的目录</h2>')
    $maxDir = 1
    if ($d.TopDirs.Count -gt 0) { $maxDir = $d.TopDirs[0].Bytes }
    [void]$sb.AppendLine('<table><tr><th>目录</th><th class="num">大小</th><th style="width:180px">占比</th><th class="num">文件数</th></tr>')
    foreach ($x in $d.TopDirs) {
        $w = [math]::Round($x.Bytes / $maxDir * 100, 1)
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td><div class="mini"><i style="width:{2}%"></i></div></td><td class="num">{3:N0}</td></tr>' -f (Esc $x.Path), (Format-Size $x.Bytes), $w, $x.Files))
    }
    [void]$sb.AppendLine('</table>')

    # 大文件
    [void]$sb.AppendLine('<h2>最大的单个文件</h2>')
    [void]$sb.AppendLine('<table><tr><th>文件</th><th class="num">大小</th><th class="num">修改日期</th></tr>')
    foreach ($x in $d.BigFiles) {
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="num p">{2}</td></tr>' -f (Esc $x.Path), (Format-Size $x.Bytes), $x.Modified))
    }
    [void]$sb.AppendLine('</table>')

    # 迁移建议
    [void]$sb.AppendLine('<h2>可以迁移到其他盘的数据</h2>')
    [void]$sb.AppendLine('<div class="note">这些目录体积大、读写不频繁，迁到 D/E 盘后在本机建立目录联接（junction），程序仍按原路径访问，无感知。</div>')
    [void]$sb.AppendLine('<table><tr><th>目录</th><th class="num">大小</th><th>建议目标</th></tr>')
    foreach ($m in $d.Migrate) {
        [void]$sb.AppendLine(('<tr><td class="p">{0}</td><td class="num">{1}</td><td class="p"><code>{2}</code></td></tr>' -f (Esc $m.Path), (Format-Size $m.Bytes), (Esc $m.Suggestion)))
    }
    [void]$sb.AppendLine('</table>')

    [void]$sb.AppendLine(('<footer>由 CDiskDoctor v{0} 生成于 {1} &nbsp;|&nbsp; 报告不含任何上传，全部在本机完成</footer>' -f $Version, $d.When))
    [void]$sb.AppendLine('</div></body></html>')

    $enc = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($FilePath, $sb.ToString(), $enc)
}

# ============================================================
#  Analyze
# ============================================================
function Invoke-Analyze {
    Write-Host ''
    Write-Host '  CDiskDoctor  ' -ForegroundColor Cyan -NoNewline
    Write-Host "v$Version  -  C 盘空间诊断" -ForegroundColor Gray
    Write-Host ('  ' + ('-' * 56)) -ForegroundColor DarkGray

    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if (-not $vol) { $vol = Get-CimInstance Win32_LogicalDisk | Where-Object { $_.DeviceID -eq 'C:' } }

    Write-Host '  [1/4] 扫描磁盘目录...' -ForegroundColor Yellow -NoNewline
    $scan = Invoke-Scan -ScanRoot $Root -BigFileMB 200
    Write-Host (" 完成  {0:N2} GB / {1:N0} 文件 / {2}s" -f ($scan.Bytes/1GB), $scan.Files, $scan.Elapsed) -ForegroundColor Green

    Write-Host '  [2/4] 计算可清理项...' -ForegroundColor Yellow -NoNewline
    $rulesRaw = Get-Rules
    $rules = New-Object System.Collections.ArrayList
    $cacheRoots = @("$env:APPDATA\kingsoft", "$env:APPDATA\LarkShell", "$env:APPDATA\Tencent",
                    "$env:APPDATA\DingTalk", "$env:APPDATA\adspower_global",
                    "$env:APPDATA\quark-cloud-drive", "$env:APPDATA\PigBun",
                    "$env:LOCALAPPDATA\JianyingPro", "$env:LOCALAPPDATA\NetEase",
                    "$env:LOCALAPPDATA\QuarkCloudDrive", "$env:LOCALAPPDATA\OpenAI")
    foreach ($rr in $rulesRaw) {
        $r = [pscustomobject]$rr
        if ($r.AutoCache) {
            $r | Add-Member -NotePropertyName CacheScanPaths -NotePropertyValue $cacheRoots -Force
        }
        $m = Measure-Rule -Rule $r -Scan $scan
        $r | Add-Member -NotePropertyName Bytes -NotePropertyValue $m.Bytes -Force
        $r | Add-Member -NotePropertyName Files -NotePropertyValue $m.Files -Force
        $r | Add-Member -NotePropertyName RealPaths -NotePropertyValue $m.Paths -Force
        [void]$rules.Add($r)
    }
    $rules = @($rules)
    Write-Host ' 完成' -ForegroundColor Green

    Write-Host '  [3/4] 分析迁移候选...' -ForegroundColor Yellow -NoNewline
    $skipRoots = @("$env:LOCALAPPDATA\Temp", "$env:LOCALAPPDATA\Microsoft", "$env:LOCALAPPDATA\Packages",
                   "$env:APPDATA\Microsoft", "$env:APPDATA\LarkShell\update")
    $migrate = New-Object System.Collections.ArrayList
    $candRoots = @($env:APPDATA, $env:LOCALAPPDATA)
    $seen = @{}
    foreach ($cr in $candRoots) {
        foreach ($child in @($scan.ByDir.Keys | Where-Object { $_ -like "$cr\*" -and ($_.Substring($cr.Length + 1) -notlike '*\*') })) {
            $sz = [long]$scan.ByDir[$child]
            if ($sz -lt 800MB) { continue }
            $skip = $false
            foreach ($s in $skipRoots) { if ($child -like "$s*") { $skip = $true } }
            if ($skip) { continue }
            if ($seen.ContainsKey($child)) { continue }
            $seen[$child] = 1
            [void]$migrate.Add([pscustomobject]@{ Path = $child; Bytes = $sz })
        }
    }
    $migrate = @($migrate | Sort-Object -Property Bytes -Descending | Select-Object -First 12)
    foreach ($m in $migrate) {
        $leaf = Split-Path $m.Path -Leaf
        $m | Add-Member -NotePropertyName Suggestion -NotePropertyValue ("D:\MovedData\{0}" -f $leaf) -Force
    }
    Write-Host ' 完成' -ForegroundColor Green

    # 目录 Top
    $top = New-Object System.Collections.ArrayList
    foreach ($k in $scan.ByDir.Keys) {
        $depth = ($k.TrimEnd('\') -split '\\').Count - 1
        if ($depth -lt 2) { continue }
        $sz = [long]$scan.ByDir[$k]
        if ($sz -lt 500MB) { continue }
        [void]$top.Add([pscustomobject]@{ Path = $k; Bytes = $sz; Files = [long]$scan.DirFiles[$k]; Depth = $depth })
    }
    $top = @($top | Sort-Object -Property Bytes -Descending | Select-Object -First 22)

    $bigFiles = @($scan.BigFiles | Sort-Object -Property Bytes -Descending | Select-Object -First 20)

    Write-Host '  [4/4] 生成报告...' -ForegroundColor Yellow -NoNewline
    $when = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $sysUsage = @(Get-SystemUsage -Drive 'C:')
    $data = [pscustomobject]@{
        When = $when; Files = $scan.Files; Dirs = $scan.Dirs; Elapsed = $scan.Elapsed
        DiskTotal = if ($vol) { $vol.Size } else { 0 }
        DiskFree = if ($vol) { $vol.FreeSpace } else { 0 }
        Rules = @($rules | Where-Object { $_.Bytes -gt 0 })
        TopDirs = $top
        BigFiles = $bigFiles
        Migrate = $migrate
        SystemUsage = $sysUsage
    }

    if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $htmlPath = Join-Path $OutDir "CDiskDoctor-Report-$stamp.html"
    New-Report -Data $data -FilePath $htmlPath
    $jsonPath = Join-Path $OutDir "CDiskDoctor-Data-$stamp.json"
    $data | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $jsonPath -Encoding UTF8
    Write-Host ' 完成' -ForegroundColor Green

    # 控制台摘要
    Write-Host ''
    Write-Host ('  剩余空间 : {0:N2} GB / {1:N0} GB  ({2}% 可用)' -f ($data.DiskFree/1GB), ($data.DiskTotal/1GB), [math]::Round($data.DiskFree/$data.DiskTotal*100,1)) -ForegroundColor White
    Write-Host ''

    if ($data.SystemUsage.Count -gt 0) {
        Write-Host '  系统级占用（普通清理工具看不到）:' -ForegroundColor Magenta
        foreach ($s in $data.SystemUsage) {
            $col = 'Gray'
            if ($s.Severity -eq 'bad') { $col = 'Red' }
            elseif ($s.Severity -eq 'warn') { $col = 'Yellow' }
            Write-Host ('    {0,-28} {1,10}  {2}' -f $s.Name, (Format-Size $s.Bytes), $s.Advice) -ForegroundColor $col
        }
        Write-Host ''
    }
    Write-Host '  可安全清理:' -ForegroundColor Green
    foreach ($r in ($data.Rules | Where-Object { $_.Risk -eq 'Safe' } | Sort-Object -Property Bytes -Descending)) {
        Write-Host ('    {0,-32} {1,10}' -f $r.Name, (Format-Size $r.Bytes)) -ForegroundColor Gray
    }
    $safeSum = ($data.Rules | Where-Object { $_.Risk -eq 'Safe' } | Measure-Object -Property Bytes -Sum).Sum
    Write-Host ('    {0,-32} {1,10}' -f '小计', (Format-Size $safeSum)) -ForegroundColor Green

    Write-Host ''
    Write-Host '  需确认后清理:' -ForegroundColor Yellow
    foreach ($r in ($data.Rules | Where-Object { $_.Risk -eq 'Caution' } | Sort-Object -Property Bytes -Descending)) {
        Write-Host ('    {0,-32} {1,10}' -f $r.Name, (Format-Size $r.Bytes)) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host '  建议迁移:' -ForegroundColor Cyan
    foreach ($m in $data.Migrate) {
        Write-Host ('    {0,-52} {1,9}' -f (Split-Path $m.Path -Leaf), (Format-Size $m.Bytes)) -ForegroundColor Gray
    }

    Write-Host ''
    Write-Host ('  报告: ' + $htmlPath) -ForegroundColor Cyan
    if ($OpenReport) { Start-Process $htmlPath }
    return $data
}

# ============================================================
#  Clean
# ============================================================
function Invoke-Clean {
    $doApply = $Apply -and -not $DryRun

    Write-Host ''
    Write-Host '  CDiskDoctor  ' -ForegroundColor Cyan -NoNewline
    Write-Host $(if ($doApply) { 'v1.0  -  清理模式（将真实删除）' } else { 'v1.0  -  清理预览（不会删除任何文件）' }) -ForegroundColor Gray
    Write-Host ('  ' + ('-' * 56)) -ForegroundColor DarkGray

    $rules = @(Get-Rules | ForEach-Object { [pscustomobject]$_ })
    $cacheRoots = @("$env:APPDATA\kingsoft", "$env:APPDATA\LarkShell", "$env:APPDATA\Tencent",
                    "$env:APPDATA\DingTalk", "$env:APPDATA\adspower_global",
                    "$env:APPDATA\quark-cloud-drive", "$env:APPDATA\PigBun",
                    "$env:LOCALAPPDATA\JianyingPro", "$env:LOCALAPPDATA\NetEase",
                    "$env:LOCALAPPDATA\QuarkCloudDrive", "$env:LOCALAPPDATA\OpenAI")
    foreach ($r in $rules) { if ($r.AutoCache) { $r | Add-Member -NotePropertyName CacheScanPaths -NotePropertyValue $cacheRoots -Force } }
    $selected = @()
    foreach ($r in $rules) {
        if ($Categories -and $Categories.Count -gt 0) {
            if ($Categories -notcontains $r.Id) { continue }
        } else {
            if ($r.Risk -ne 'Safe') { continue }
        }
        $selected += $r
    }
    if ($selected.Count -eq 0) {
        Write-Host '  没有匹配的清理类别。' -ForegroundColor Yellow
        return
    }

    $log = New-Object System.Collections.ArrayList
    $totalFreed = [long]0
    $totalDeleted = 0
    $totalFailed = 0

    foreach ($r in $selected) {
        $m = Measure-Rule -Rule $r -Scan $null
        if (-not $m.Exists -or $m.Bytes -le 0) { continue }

        Write-Host ('  {0,-30} {1,10}' -f $r.Name, (Format-Size $m.Bytes)) -ForegroundColor White -NoNewline

        if (-not $doApply) {
            Write-Host '  [预览]' -ForegroundColor DarkGray
            [void]$log.Add(('PREVIEW  {0,-30} {1}' -f $r.Name, (Format-Size $m.Bytes)))
            $totalFreed += $m.Bytes
            continue
        }

        $f = [long]0
        if ($r.Special -eq 'Recycle') {
            try {
                $before = Measure-Tree -Path 'C:\$Recycle.Bin'
                Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue
                $after = Measure-Tree -Path 'C:\$Recycle.Bin'
                $f = [math]::Max(0, $before.Bytes - $after.Bytes)
            } catch {}
        } else {
            foreach ($p in $m.Paths) {
                $res = Remove-Junk -Path $p -Include $r.Include -AgeDays $r.Age -ForceDelete:$Force -Log $log
                $f += $res.Freed
                $totalDeleted += $res.Deleted
                $totalFailed += $res.Failed
            }
        }
        $totalFreed += $f
        Write-Host ('  -{0}' -f (Format-Size $f)) -ForegroundColor Green
    }

    Write-Host ('  ' + ('-' * 56)) -ForegroundColor DarkGray
    if ($doApply) {
        Write-Host ('  本次释放: {0}   删除文件 {1:N0} 个   失败 {2} 个' -f (Format-Size $totalFreed), $totalDeleted, $totalFailed) -ForegroundColor Green
    } else {
        Write-Host ('  预计可释放: {0}' -f (Format-Size $totalFreed)) -ForegroundColor Green
        Write-Host '  这是预览。加 -Apply 才会真正删除。' -ForegroundColor Yellow
    }

    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if ($vol) {
        Write-Host ('  C 盘剩余: {0:N2} GB ({1}%)' -f ($vol.FreeSpace/1GB), [math]::Round($vol.FreeSpace/$vol.Size*100,1)) -ForegroundColor Cyan
    }

    if ($doApply) {
        $logPath = Join-Path $OutDir ("clean-{0}.log" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        $log | Set-Content -Path $logPath -Encoding UTF8
        Write-Host ('  日志: ' + $logPath) -ForegroundColor DarkGray
    }
}

# ============================================================
#  Migrate
# ============================================================
function Invoke-Migrate {
    if ($Rollback) {
        $link = $Rollback.TrimEnd('\')
        if (-not (Test-Path -LiteralPath $link)) { Write-Host '  路径不存在。' -ForegroundColor Red; return }
        $item = Get-Item -LiteralPath $link -Force
        if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Write-Host '  该路径不是联接点，无法回滚。' -ForegroundColor Red; return
        }
        $target = $item.Target
        if ($target -is [array]) { $target = $target[0] }
        Write-Host ('  联接点 -> ' + $target) -ForegroundColor Gray
        if (-not (Test-Path -LiteralPath $target)) { Write-Host '  目标数据不存在，已中止。' -ForegroundColor Red; return }
        if (-not $Apply) { Write-Host '  预览：将删除联接点并把数据搬回原位置。加 -Apply 执行。' -ForegroundColor Yellow; return }
        cmd /c rmdir "$link"
        New-Item -ItemType Directory -Path $link | Out-Null
        robocopy "$target" "$link" /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
        Write-Host '  已回滚。' -ForegroundColor Green
        return
    }

    if (-not $Path -or -not $Target) {
        Write-Host '  用法: -Mode Migrate -Path <源目录> -Target <目标根目录> [-Apply]' -ForegroundColor Yellow
        return
    }
    $src = (Resolve-Path -LiteralPath $Path).Path
    $leaf = Split-Path $src -Leaf
    $dest = Join-Path $Target $leaf

    if (-not (Test-Path -LiteralPath $src)) { Write-Host '  源目录不存在。' -ForegroundColor Red; return }
    $item = Get-Item -LiteralPath $src -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { Write-Host '  源目录已经是联接点。' -ForegroundColor Red; return }

    $m = Measure-Tree -Path $src
    Write-Host ''
    Write-Host ('  源目录 : ' + $src) -ForegroundColor White
    Write-Host ('  大小   : ' + (Format-Size $m.Bytes) + ('  ({0:N0} 个文件)' -f $m.Files)) -ForegroundColor Gray
    Write-Host ('  目标   : ' + $dest) -ForegroundColor White
    Write-Host ''

    if (-not $Apply) {
        Write-Host '  预览模式，不会执行。确认无误后加 -Apply。' -ForegroundColor Yellow
        Write-Host '  执行时会: 1) robocopy 复制并校验  2) 重命名源目录  3) 建立 junction  4) 校验通过后删除源' -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
    if (Test-Path -LiteralPath $dest) { Write-Host '  目标已存在，已中止以免覆盖。' -ForegroundColor Red; return }

    Write-Host '  [1/4] 复制中...' -ForegroundColor Yellow -NoNewline
    $rc = (Start-Process robocopy -ArgumentList @("`"$src`"", "`"$dest`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
    if ($rc -ge 8) { Write-Host ' 复制失败，已中止。' -ForegroundColor Red; return }
    Write-Host ' 完成' -ForegroundColor Green

    Write-Host '  [2/4] 校验...' -ForegroundColor Yellow -NoNewline
    $m2 = Measure-Tree -Path $dest
    if ($m2.Files -lt $m.Files) {
        Write-Host (' 文件数不一致（{0} vs {1}），已中止，源目录未动。' -f $m2.Files, $m.Files) -ForegroundColor Red
        return
    }
    Write-Host ' 通过' -ForegroundColor Green

    Write-Host '  [3/4] 切换为联接点...' -ForegroundColor Yellow -NoNewline
    $backup = $src + '.old'
    try {
        Rename-Item -LiteralPath $src -NewName (Split-Path $backup -Leaf) -ErrorAction Stop
    } catch {
        Write-Host ' 重命名失败（可能被程序占用），已中止。' -ForegroundColor Red
        return
    }
    cmd /c mklink /J "$src" "$dest" | Out-Null
    $check = Get-Item -LiteralPath $src -Force
    if (-not ($check.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Host ' 建立联接失败，正在回滚...' -ForegroundColor Red
        Rename-Item -LiteralPath $backup -NewName $leaf
        return
    }
    Write-Host ' 完成' -ForegroundColor Green

    Write-Host '  [4/4] 清理源目录...' -ForegroundColor Yellow -NoNewline
    Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $backup) {
        Write-Host ' 部分残留，请手动删除 ' -ForegroundColor Yellow -NoNewline
        Write-Host $backup -ForegroundColor DarkGray
    } else {
        Write-Host ' 完成' -ForegroundColor Green
    }

    Write-Host ''
    Write-Host ('  已迁移: ' + $src + '  ->  ' + $dest) -ForegroundColor Green
    Write-Host ('  释放 C 盘: ' + (Format-Size $m.Bytes)) -ForegroundColor Green
}

# ============================================================
#  系统级占用：页面文件 / 休眠文件 / 交换文件 / 搜索索引
#  这些不是"垃圾"，但放错盘会白占几个甚至十几个 GB，
#  普通清理工具（含早期的本工具）都发现不了。
# ============================================================
function Get-SystemUsage {
    param([string]$Drive = 'C:')

    $out = New-Object System.Collections.ArrayList
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $auto = $false
    if ($cs) { $auto = $cs.AutomaticManagedPagefile }

    # 页面文件
    $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    $rootPf = @($pf | Where-Object { $_.Name -like "$Drive\*" })
    if ($rootPf.Count -gt 0) {
        $sumMB = ($rootPf | Measure-Object -Property AllocatedBaseSize -Sum).Sum
        $bytes = [long]$sumMB * 1MB
        if ($bytes -gt 2GB) {
            if ($auto) {
                $adv = 'Windows「自动管理」把页面文件放到了系统盘。用 -Mode System -Apply 迁到其他盘'
            } else {
                $adv = '页面文件固定在系统盘，可用 -Mode System -Apply 迁到其他盘'
            }
            [void]$out.Add([pscustomobject]@{ Name = '页面文件 pagefile.sys'; Bytes = $bytes; Severity = 'bad'; Advice = $adv })
        } else {
            [void]$out.Add([pscustomobject]@{ Name = '页面文件 pagefile.sys'; Bytes = $bytes; Severity = 'safe'; Advice = '大小合理，保留用于蓝屏转储' })
        }
    }

    # 休眠文件
    $hb = Get-Item "$Drive\hiberfil.sys" -Force -ErrorAction SilentlyContinue
    if ($hb) {
        [void]$out.Add([pscustomobject]@{ Name = '休眠文件 hiberfil.sys'; Bytes = [long]$hb.Length; Severity = 'warn'; Advice = '不需要休眠时执行 powercfg /h off 可回收' })
    }

    # 交换文件
    $sw = Get-Item "$Drive\swapfile.sys" -Force -ErrorAction SilentlyContinue
    if ($sw) {
        [void]$out.Add([pscustomobject]@{ Name = '交换文件 swapfile.sys'; Bytes = [long]$sw.Length; Severity = 'safe'; Advice = 'UWP 应用使用，无需处理' })
    }

    # 搜索索引
    $edb = Get-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force -ErrorAction SilentlyContinue
    if ($edb -and $edb.Length -gt 512MB) {
        [void]$out.Add([pscustomobject]@{ Name = '搜索索引 Windows.edb'; Bytes = [long]$edb.Length; Severity = 'warn'; Advice = '体积偏大，可在「索引选项」中重建（会短暂影响搜索）' })
    }

    return @($out)
}

function Invoke-SystemCheck {
    param([switch]$ApplyFix)

    Write-Host ''
    Write-Host '  CDiskDoctor  ' -ForegroundColor Cyan -NoNewline
    Write-Host "v$Version  -  系统级占用检查" -ForegroundColor Gray
    Write-Host ('  ' + ('-' * 56)) -ForegroundColor DarkGray

    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $auto = $false
    if ($cs) { $auto = $cs.AutomaticManagedPagefile }

    $pfUsage = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)

    Write-Host '  页面文件:' -ForegroundColor White
    if ($pfUsage.Count -eq 0) {
        Write-Host '    （没有页面文件）' -ForegroundColor DarkGray
    } else {
        foreach ($u in $pfUsage) {
            Write-Host ('    {0,-28} {1,10:N0} MB' -f $u.Name, $u.AllocatedBaseSize) -ForegroundColor Gray
        }
    }
    Write-Host ('    自动管理: ' + $auto) -ForegroundColor DarkGray

    $rootPfMB = 0
    foreach ($u in $pfUsage) { if ($u.Name -like 'C:\*') { $rootPfMB += [long]$u.AllocatedBaseSize } }

    # 休眠 / 交换
    $hb = Get-Item 'C:\hiberfil.sys' -Force -ErrorAction SilentlyContinue
    if ($hb) {
        Write-Host ('  休眠文件: {0:N2} GB  （不需要休眠可执行 powercfg /h off 回收）' -f ($hb.Length/1GB)) -ForegroundColor Yellow
    } else {
        Write-Host '  休眠文件: 无' -ForegroundColor DarkGray
    }

    Write-Host ''
    if ($rootPfMB -gt 2048) {
        Write-Host ('  [!] 页面文件在 C 盘占用 {0:N1} GB，这是最常见的"空间莫名消失"原因。' -f ($rootPfMB/1024)) -ForegroundColor Yellow
        if ($auto) {
            Write-Host '      当前由「自动管理」决定位置——只要 C 盘空间变多，Windows 就可能把它挪回来。' -ForegroundColor DarkGray
        }

        if (-not $ApplyFix) {
            Write-Host ''
            Write-Host '  修复: 加 -Apply 把主页面文件迁到其他盘，C 盘只留 1 GB。' -ForegroundColor Cyan
            Write-Host '        powershell -ExecutionPolicy Bypass -File src\CDiskDoctor.ps1 -Mode System -Apply' -ForegroundColor DarkGray
            return
        }

        $targets = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' |
                     Where-Object { $_.DeviceID -ne 'C:' -and $_.FreeSpace -gt 10GB } |
                     Sort-Object -Property FreeSpace -Descending)
        if ($targets.Count -eq 0) {
            Write-Host '  [x] 没有可用空间超过 10 GB 的其他磁盘，已中止。' -ForegroundColor Red
            return
        }
        $target = $targets[0].DeviceID
        Write-Host ("  目标盘: {0}（可用 {1:N0} GB）" -f $target, ($targets[0].FreeSpace/1GB)) -ForegroundColor Gray

        try {
            $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false }
            $mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
            Set-ItemProperty -Path $mm -Name PagingFiles `
                -Value @("C:\pagefile.sys 1024 1024", "$target\pagefile.sys 0 0") -Type MultiString
            Write-Host '  [√] 配置已写入' -ForegroundColor Green
            Write-Host ("      C:\pagefile.sys   1024 MB（保留蓝屏转储能力）") -ForegroundColor DarkGray
            Write-Host ("      {0}\pagefile.sys  系统管理" -f $target) -ForegroundColor DarkGray
            Write-Host ''
            Write-Host ('  [i] 需要重启才能生效，预计回收 {0:N1} GB。' -f (($rootPfMB - 1024)/1024)) -ForegroundColor Yellow
        } catch {
            Write-Host ('  [x] 写入失败: ' + $_.Exception.Message) -ForegroundColor Red
        }
    } else {
        Write-Host '  [√] 页面文件不在 C 盘或体积正常，无异常占用。' -ForegroundColor Green
    }
}

# ============================================================
#  入口
# ============================================================
switch ($Mode) {
    'Analyze' { Invoke-Analyze | Out-Null }
    'Clean'   { Invoke-Clean }
    'Migrate' { Invoke-Migrate }
    'System'  { Invoke-SystemCheck -ApplyFix:$Apply }
    'Help'    {
        Write-Host @'

  CDiskDoctor v1.1 - C 盘空间诊断 / 清理 / 迁移

  Analyze  分析并生成 HTML 报告（只读）
      -Mode Analyze [-OpenReport]

  Clean    清理
      -Mode Clean [-DryRun]           预览
      -Mode Clean -Apply              执行安全清理
      -Mode Clean -Apply -Categories TempUser,EdgeCache,AppCache
      -Mode Clean -Apply -Force       忽略"最近修改"保护，强制删除

      类别: TempUser TempWindows CrashDump WinLogs UpdateCache
            ThumbCache IconCache UpdaterFiles EdgeCache ChromeCache
            RecycleBin AppCache DevCache Prefetch SearchIndex

  Migrate  迁移大目录到其他盘并建立软链接
      -Mode Migrate -Path <源> -Target <目标根>       预览
      -Mode Migrate -Path <源> -Target <目标根> -Apply
      -Mode Migrate -Rollback <原路径> -Apply        回滚

  System   系统级占用检查（页面文件 / 休眠文件 / 搜索索引）
      -Mode System                    只检查
      -Mode System -Apply             把页面文件迁出 C 盘（需重启生效）

'@ -ForegroundColor Gray
    }
}