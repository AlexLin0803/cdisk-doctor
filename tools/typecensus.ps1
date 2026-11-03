<#
  TypeCensus - 按文件类型 + 所在区域，统计 C 盘文件占用（只读）
  Usage: powershell -File typecensus.ps1 -Root C:\ -BigMB 50 -Out census.json
#>
param(
    [string]$Root = 'C:\',
    [int]$BigMB = 50,
    [string]$Out = 'census.json'
)
$ErrorActionPreference = 'SilentlyContinue'

$rootFull = [System.IO.Path]::GetFullPath($Root)
$bigBytes = [long]$BigMB * 1MB

$byExt = @{}
$bigList = New-Object System.Collections.ArrayList

function Get-Zone([string]$p) {
    $x = $p.ToLower()
    if ($x.StartsWith('c:\windows')) { return 'Windows' }
    if ($x.StartsWith('c:\program files')) { return 'ProgramFiles' }
    if ($x.StartsWith('c:\programdata')) { return 'ProgramData' }
    if ($x.StartsWith('c:\users')) {
        if ($x -match '\\appdata\\local\\temp\\') { return 'Temp' }
        if ($x -match '\\appdata\\') { return 'AppData' }
        if ($x -match '\\downloads\\') { return 'Downloads' }
        if ($x -match '\\desktop\\') { return 'Desktop' }
        if ($x -match '\\documents\\') { return 'Documents' }
        return 'UserHome'
    }
    if ($x.StartsWith('c:\$recycle.bin')) { return 'Recycle' }
    if ($x.StartsWith('c:\system volume information')) { return 'SystemVolume' }
    return 'Other'
}

$stack = New-Object System.Collections.Stack
$stack.Push($rootFull)
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fileCount = 0
$totalBytes = [long]0

while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try {
        $di = New-Object System.IO.DirectoryInfo $d
        foreach ($fi in $di.EnumerateFiles()) {
            try {
                $len = [long]$fi.Length
                $ext = $fi.Extension.ToLower()
                if ([string]::IsNullOrEmpty($ext)) { $ext = '(无扩展名)' }
                $key = $ext
                if (-not $byExt.ContainsKey($key)) {
                    $byExt[$key] = [pscustomobject]@{ Ext = $key; Bytes = [long]0; Count = [long]0; Zones = @{} }
                }
                $byExt[$key].Bytes += $len
                $byExt[$key].Count++
                $z = Get-Zone $fi.FullName
                if (-not $byExt[$key].Zones.ContainsKey($z)) { $byExt[$key].Zones[$z] = [long]0 }
                $byExt[$key].Zones[$z] += $len

                $fileCount++
                $totalBytes += $len

                if ($len -ge $bigBytes) {
                    [void]$bigList.Add([pscustomobject]@{
                        Path = $fi.FullName; Bytes = $len; Ext = $ext
                        Zone = $z; Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd')
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

$extOut = @()
foreach ($k in $byExt.Keys) {
    $o = $byExt[$k]
    $zones = @{}
    foreach ($zk in $o.Zones.Keys) { $zones[$zk] = $o.Zones[$zk] }
    $extOut += [pscustomobject]@{ Ext = $k; Bytes = $o.Bytes; Count = $o.Count; Zones = $zones }
}

$payload = [pscustomobject]@{
    Root = $rootFull
    TotalBytes = $totalBytes
    TotalFiles = $fileCount
    Elapsed = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Extensions = @($extOut | Sort-Object Bytes -Descending)
    BigFiles = @($bigList | Sort-Object Bytes -Descending | Select-Object -First 300)
}
$payload | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $Out -Encoding UTF8
Write-Output ("CENSUS_DONE total={0:N2}GB files={1:N0} ext={2} big={3} elapsed={4}s" -f ($totalBytes/1GB), $fileCount, $extOut.Count, $bigList.Count, [math]::Round($sw.Elapsed.TotalSeconds,1))