<#
  TopDirs - 列出某目录下各一级子目录的大小（跳过联接点）
  用法: powershell -File topdirs.ps1 -Parent "C:\Users\<用户名>\AppData\Roaming" [-Top 25]
#>
param(
    [Parameter(Mandatory=$true)][string]$Parent,
    [int]$Top = 25
)

$ErrorActionPreference = 'SilentlyContinue'

function Measure-Tree {
    param([string]$Path)
    $bytes = [long]0; $files = [long]0
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
    [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

$rows = New-Object System.Collections.ArrayList
$direct = [long]0
$di = New-Object System.IO.DirectoryInfo $Parent
foreach ($fi in $di.EnumerateFiles()) { $direct += $fi.Length }

foreach ($sub in $di.EnumerateDirectories()) {
    if (($sub.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
    $m = Measure-Tree -Path $sub.FullName
    [void]$rows.Add([pscustomobject]@{ Name = $sub.Name; MB = [math]::Round($m.Bytes/1MB,1); GB = [math]::Round($m.Bytes/1GB,2); Files = $m.Files })
}

Write-Output ("== {0} (直接文件 {1:N1} MB) ==" -f $Parent, ($direct/1MB))
$rows | Sort-Object MB -Descending | Select-Object -First $Top | Format-Table -AutoSize