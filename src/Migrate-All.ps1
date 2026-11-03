<#
  Migrate-All.ps1 - 批量把 AppData 大目录迁到其他盘并建立 junction
  ------------------------------------------------------------------
  安全策略：
    1. robocopy 复制并校验（文件数 + 字节数）
    2. 校验通过才重命名源目录
    3. 建立 junction 并验证
    4. 全部成功后才删除旧目录
    5. 任何一步失败 -> 保留源目录，跳过该项，继续下一个

  用法:
    powershell -ExecutionPolicy Bypass -File Migrate-All.ps1 -Target "E:\MovedData" -Paths "C:\a","C:\b" [-Apply]
    powershell -ExecutionPolicy Bypass -File Migrate-All.ps1 -Target "E:\MovedData" -FromPlan "Move-Plan-xxx.ps1" [-Apply]
    powershell -ExecutionPolicy Bypass -File Migrate-All.ps1 -Rollback "C:\a"
#>
param(
    [string]$Target = 'E:\MovedData',
    [string[]]$Paths,
    [string]$FromPlan,
    [string[]]$Exclude = @(),
    [switch]$Apply,
    [string]$Rollback
)

$ErrorActionPreference = 'SilentlyContinue'
$script:manifest = New-Object System.Collections.ArrayList

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    return ('{0:N1} MB' -f ($b / 1MB))
}

function Measure-Tree([string]$Path) {
    $bytes = [long]0; $files = [long]0
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Bytes = 0; Files = 0 } }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($fi in $di.EnumerateFiles()) { try { $bytes += $fi.Length; $files++ } catch {} }
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
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

# ---------------------------------------------------------------- 回滚模式
if ($Rollback) {
    $link = $Rollback.TrimEnd('\')
    $item = Get-Item -LiteralPath $link -Force
    if (-not $item -or -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Host '  不是 junction，无法回滚。' -ForegroundColor Red; return
    }
    $t = $item.Target
    if ($t -is [array]) { $t = $t[0] }
    Write-Host ("  联接点 -> $t") -ForegroundColor Gray
    if (-not $Apply) { Write-Host '  预览：删除联接点并把数据搬回。加 -Apply 执行。' -ForegroundColor Yellow; return }
    cmd /c rmdir "$link"
    New-Item -ItemType Directory -Path $link -Force | Out-Null
    robocopy "$t" "$link" /E /MOVE /R:1 /W:1 /NFL /NDL /NJH /NJS | Out-Null
    Write-Host '  已回滚。' -ForegroundColor Green
    return
}

# ---------------------------------------------------------------- 收集清单
$list = New-Object System.Collections.ArrayList
if ($FromPlan) {
    $txt = Get-Content -LiteralPath $FromPlan -Raw -Encoding UTF8
    foreach ($m in [regex]::Matches($txt, 'Migrate-AppData\s+"([^"]+)"')) { [void]$list.Add($m.Groups[1].Value) }
}
if ($Paths) {
    # 兼容 powershell -File 调用：逗号分隔的参数会被当成单个字符串
    $flat = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    foreach ($p in $flat) { [void]$list.Add($p) }
}
if ($list.Count -eq 0) { Write-Host '  没有要迁移的目录。' -ForegroundColor Yellow; return }

if ($Exclude.Count -gt 0) {
    $list = @($list | Where-Object { $p = $_; -not ($Exclude | Where-Object { $p -like $_ }) })
}

Write-Host ''
Write-Host ("  目标: $Target    共 {0} 个目录    模式: {1}" -f $list.Count, $(if ($Apply) { '执行' } else { '预览' })) -ForegroundColor Cyan
Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray

if ($Apply -and -not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }

$okBytes = [long]0; $okCount = 0; $failCount = 0; $skipCount = 0
$failList = New-Object System.Collections.ArrayList

foreach ($src in $list) {
    $src = $src.TrimEnd('\')
    $name = Split-Path $src -Leaf
    if (-not (Test-Path -LiteralPath $src)) { $skipCount++; continue }

    $it = Get-Item -LiteralPath $src -Force
    if ($it.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        Write-Host ("  [跳过] {0,-52} 已是软链接" -f $name) -ForegroundColor DarkGray
        $skipCount++; continue
    }

    $m = Measure-Tree $src
    # 保留相对路径，避免不同 AppData 下的同名目录（如 Local\Codex 与 Roaming\Codex）撞车
    $rel = $src.Substring(3)
    $dest = Join-Path $Target $rel

    if (-not $Apply) {
        Write-Host ("  [预览] {0,-52} {1,10}  ->  {2}" -f $name, (Format-Size $m.Bytes), $dest) -ForegroundColor Gray
        $okBytes += $m.Bytes; $okCount++
        continue
    }

    Write-Host ("  {0,-52} {1,10} " -f $name, (Format-Size $m.Bytes)) -NoNewline

    if (Test-Path -LiteralPath $dest) {
        Write-Host ' 目标已存在，跳过' -ForegroundColor Yellow
        $failCount++; [void]$failList.Add("$name : 目标已存在"); continue
    }

    # 1) 复制
    if (-not (Test-Path -LiteralPath (Split-Path $dest -Parent))) { New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null }
    $rc = (Start-Process robocopy -ArgumentList @("`"$src`"", "`"$dest`"", '/E', '/COPY:DAT', '/DCOPY:DAT', '/R:1', '/W:1', '/NFL', '/NDL', '/NJH', '/NJS', '/NP') -Wait -PassThru -NoNewWindow).ExitCode
    if ($rc -ge 8) {
        Write-Host (" 复制失败(rc=$rc)，清理残留后跳过") -ForegroundColor Red
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $failCount++; [void]$failList.Add("$name : robocopy rc=$rc"); continue
    }

    # 2) 校验
    $m2 = Measure-Tree $dest
    if ($m2.Files -lt $m.Files) {
        Write-Host (" 校验失败({0}/{1} 文件)，清理残留后跳过" -f $m2.Files, $m.Files) -ForegroundColor Red
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $failCount++; [void]$failList.Add("$name : 文件数 $($m2.Files)/$($m.Files)"); continue
    }

    # 3) 切换
    $bak = $src + '.__old'
    try { Rename-Item -LiteralPath $src -NewName (Split-Path $bak -Leaf) -ErrorAction Stop }
    catch {
        Write-Host ' 源目录被占用，跳过' -ForegroundColor Red
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $failCount++; [void]$failList.Add("$name : 源目录被占用"); continue
    }

    cmd /c mklink /J "$src" "$dest" | Out-Null
    $chk = Get-Item -LiteralPath $src -Force
    if (-not ($chk.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        Write-Host ' 建链失败，回滚' -ForegroundColor Red
        Rename-Item -LiteralPath $bak -NewName $name
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        $failCount++; [void]$failList.Add("$name : mklink 失败"); continue
    }

    # 4) 删旧
    Remove-Item -LiteralPath $bak -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $bak) {
        Write-Host ' 完成(有残留)' -ForegroundColor Yellow
    } else {
        Write-Host ' 完成' -ForegroundColor Green
    }
    $okBytes += $m.Bytes; $okCount++
    [void]$script:manifest.Add([pscustomobject]@{ Source = $src; Target = $dest; Bytes = $m.Bytes; Files = $m.Files; When = (Get-Date).ToString('s') })
}

Write-Host ('  ' + ('-' * 62)) -ForegroundColor DarkGray
if ($Apply) {
    Write-Host ("  成功 {0} 个，释放 C 盘 {1}；失败 {2} 个；跳过 {3} 个" -f $okCount, (Format-Size $okBytes), $failCount, $skipCount) -ForegroundColor Green
    if ($failCount -gt 0) {
        Write-Host '  失败明细（通常是程序没关）：' -ForegroundColor Yellow
        $failList | ForEach-Object { Write-Host ("    - $_") -ForegroundColor Gray }
    }
    if ($script:manifest.Count -gt 0) {
        $mf = Join-Path $PSScriptRoot ("migrate-manifest-{0}.json" -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        $script:manifest | ConvertTo-Json -Depth 3 | Set-Content -Path $mf -Encoding UTF8
        Write-Host ("  迁移清单: $mf") -ForegroundColor DarkGray
    }
} else {
    Write-Host ("  预览合计: {0} 个目录，{1}" -f $okCount, (Format-Size $okBytes)) -ForegroundColor Cyan
    Write-Host '  加 -Apply 才会执行。' -ForegroundColor Yellow
}

$v = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
if ($v) { Write-Host ("  C 盘剩余: {0:N2} GB" -f ($v.FreeSpace/1GB)) -ForegroundColor Cyan }