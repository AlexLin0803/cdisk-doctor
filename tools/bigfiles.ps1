<#
  BigFiles - List the largest individual files under a root (read-only).
  Usage: powershell -File bigfiles.ps1 -Root C:\ -MinMB 200 -Top 60 -Out big.json
#>
param(
    [string]$Root = 'C:\',
    [int]$MinMB = 200,
    [int]$Top = 60,
    [string]$Out = 'big.json'
)

$ErrorActionPreference = 'SilentlyContinue'
$rootFull = [System.IO.Path]::GetFullPath($Root)
$minBytes = [long]$MinMB * 1MB

$list = New-Object System.Collections.Generic.List[object]
$stack = New-Object System.Collections.Stack
$stack.Push($rootFull)

while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    try {
        $di = New-Object System.IO.DirectoryInfo $d
        foreach ($fi in $di.EnumerateFiles()) {
            try {
                if ($fi.Length -ge $minBytes) {
                    [void]$list.Add([pscustomobject]@{ Path = $fi.FullName; Bytes = $fi.Length; Modified = $fi.LastWriteTime.ToString('yyyy-MM-dd') })
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

$sorted = @($list | Sort-Object -Property Bytes -Descending | Select-Object -First $Top)
$sorted | ConvertTo-Json -Depth 3 -Compress | Set-Content -Path $Out -Encoding UTF8
Write-Output ("BIGFILES_DONE count=" + $sorted.Count)
$sorted | ForEach-Object { "{0,9:N2} GB  {1}  {2}" -f ($_.Bytes/1GB), $_.Modified, $_.Path }