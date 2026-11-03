# Fix-Bom.ps1
# 确保 .ps1 文件为 UTF-8 with BOM。
#
# 为什么需要：Windows PowerShell 5.1 读取无 BOM 的 UTF-8 文件时会按系统 ANSI 代码页（简体中文为 GBK）解析，
# 中文注释的字节序列可能吞掉行尾换行，把下一行代码并入注释，导致"莫名其妙的语法错误"。
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\Fix-Bom.ps1 -Root .
#   powershell -ExecutionPolicy Bypass -File tools\Fix-Bom.ps1 -Files "a.ps1,b.ps1"
param(
    [string[]]$Files,
    [string]$Root
)

$enc = New-Object System.Text.UTF8Encoding $true
$targets = @()

if ($Root) {
    $targets = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File |
                 ForEach-Object { $_.FullName })
} elseif ($Files) {
    # 兼容 powershell -File 调用：逗号分隔的数组会被合并成单个字符串
    $targets = @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

if ($targets.Count -eq 0) {
    Write-Output '没有指定文件。用 -Root . 或 -Files "a.ps1,b.ps1"'
    return
}

$fixed = 0
foreach ($f in $targets) {
    if (-not (Test-Path -LiteralPath $f)) { Write-Output "skip (missing): $f"; continue }
    $full = (Resolve-Path -LiteralPath $f).Path
    $bytes = [System.IO.File]::ReadAllBytes($full)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        continue
    }
    $text = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($full, $text, $enc)
    Write-Output "fixed: $full"
    $fixed++
}

Write-Output ("检查 {0} 个文件，修复 {1} 个" -f $targets.Count, $fixed)