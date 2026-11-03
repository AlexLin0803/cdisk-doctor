<#
  CScan - 磁盘占用扫描器
  用法: powershell -ExecutionPolicy Bypass -File scan.ps1 -Root C:\ -Out out.json [-MinMB 5]
  只读操作，不做任何修改。
#>
param(
    [string]$Root = 'C:\',
    [string]$Out = 'scan.json',
    [int]$MinMB = 5,
    [int]$TopN = 200
)

$ErrorActionPreference = 'SilentlyContinue'
$rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
if ($rootFull.Length -eq 2) { $rootFull = $rootFull + '\' }

$own = @{}        # dir -> own bytes (direct files only)
$cnt = @{}        # dir -> direct file count
$parent = @{}     # dir -> parent dir
$fileTotal = [long]0
$fileCount = [long]0
$skipDirs = 0

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
                if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                    $script:skipDirs++
                    continue
                }
                $p = $sub.FullName
                $parent[$p] = $d
                $stack.Push($p)
            } catch {}
        }
    } catch {}
}

# 自底向上汇总
$total = @{}
foreach ($k in $own.Keys) { $total[$k] = $own[$k] }
$keys = @($total.Keys)
[Array]::Sort($keys, [System.Collections.Comparer]::Default)
[Array]::Reverse($keys)   # 路径字典序倒序 ≈ 深度优先，父目录在子目录之后处理
foreach ($k in $keys) {
    if ($parent.ContainsKey($k)) {
        $pk = $parent[$k]
        if ($total.ContainsKey($pk)) { $total[$pk] = $total[$pk] + $total[$k] }
    }
}

$minBytes = [long]$MinMB * 1MB
$results = New-Object System.Collections.ArrayList
foreach ($k in $keys) {
    if ($total[$k] -ge $minBytes) {
        [void]$results.Add([pscustomobject]@{
            Path    = $k
            Bytes   = $total[$k]
            Own     = $own[$k]
            Files   = $cnt[$k]
            Depth   = ($k.TrimEnd('\').Split('\').Count - 1)
        })
    }
}

$sorted = @($results | Sort-Object -Property Bytes -Descending)

$payload = [pscustomobject]@{
    Root        = $rootFull
    GeneratedAt = (Get-Date).ToString('s')
    TotalBytes  = $fileTotal
    TotalFiles  = $fileCount
    DirCount    = $own.Count
    SkippedLinks= $script:skipDirs
    ElapsedSec  = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Dirs        = @($sorted | Select-Object -First $TopN)
}

$payload | ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $Out -Encoding UTF8

Write-Output ("SCAN_DONE root={0} total={1:N2}GB files={2:N0} dirs={3:N0} links_skipped={4} elapsed={5}s" -f `
    $rootFull, ($fileTotal/1GB), $fileCount, $own.Count, $script:skipDirs, [math]::Round($sw.Elapsed.TotalSeconds,1))