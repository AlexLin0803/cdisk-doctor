<#
  DirSize - 安全计算多个目录的大小（跳过符号链接/联接点，避免死循环）
  用法: powershell -File dirsize.ps1 -Paths "C:\a","C:\b" [-MinMB 0]
#>
param(
    [string]$List,
    [int]$MinMB = 0
)

$ErrorActionPreference = 'SilentlyContinue'
$Paths = @()
if ($List) {
    if (Test-Path -LiteralPath $List) {
        $Paths = @(Get-Content -LiteralPath $List | Where-Object { $_.Trim() -ne '' })
    } else {
        $Paths = @($List -split '\|' | Where-Object { $_.Trim() -ne '' })
    }
}

function Measure-Tree {
    param([string]$Path)
    $bytes = [long]0
    $files = [long]0
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Bytes = 0; Files = 0; Exists = $false }
    }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        try {
            $di = New-Object System.IO.DirectoryInfo $d
            foreach ($fi in $di.EnumerateFiles()) {
                try { $bytes += $fi.Length; $files++ } catch {}
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
    return [pscustomobject]@{ Bytes = $bytes; Files = $files; Exists = $true }
}

$out = New-Object System.Collections.ArrayList
foreach ($p in $Paths) {
    $r = Measure-Tree -Path $p
    if (-not $r.Exists -and $MinMB -gt 0) { continue }
    [void]$out.Add([pscustomobject]@{
        Path  = $p
        MB    = [math]::Round($r.Bytes / 1MB, 1)
        GB    = [math]::Round($r.Bytes / 1GB, 2)
        Files = $r.Files
    })
}

$out | Sort-Object MB -Descending | Format-Table -AutoSize
Write-Output ("TOTAL_MB=" + [math]::Round((($out | Measure-Object MB -Sum).Sum), 1))