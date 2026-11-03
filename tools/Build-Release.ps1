# Build-Release.ps1
# 打包可分发 ZIP（只含运行所需文件，不含 .git / .github / 开发产物）
#
# 用法：
#   powershell -ExecutionPolicy Bypass -File tools\Build-Release.ps1 -Version 1.0.0
#
# 产物：dist\cdisk-doctor-v1.0.0.zip
param(
    [string]$Version = '1.0.0',
    [string]$OutDir = 'dist'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$name = "cdisk-doctor-v$Version"
$zipPath = Join-Path (Join-Path $root $OutDir) "$name.zip"

# 运行所需文件（白名单）
$include = @(
    'Run.cmd',
    'README.md',
    'README.en.md',
    'LICENSE',
    'SECURITY.md',
    'src',
    'tools'
)

$stage = Join-Path $env:TEMP ("cdd-stage-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$stageRoot = Join-Path $stage $name
New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null

try {
    foreach ($item in $include) {
        $src = Join-Path $root $item
        if (-not (Test-Path -LiteralPath $src)) {
            Write-Warning "缺少: $item"
            continue
        }
        Copy-Item -LiteralPath $src -Destination $stageRoot -Recurse -Force
    }

    # 打包前校验所有 .ps1 的 BOM 与语法
    $bad = 0
    Get-ChildItem -Path $stageRoot -Recurse -Filter *.ps1 | ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
        if (-not $hasBom) { Write-Warning "缺少 BOM: $($_.Name)"; $bad++ }
        if ($errors.Count -gt 0) { Write-Warning "语法错误: $($_.Name) - $($errors[0].Message)"; $bad++ }
    }
    if ($bad -gt 0) { throw "打包前校验失败（$bad 处），已中止" }

    $outFull = Join-Path $root $OutDir
    if (-not (Test-Path -LiteralPath $outFull)) { New-Item -ItemType Directory -Path $outFull -Force | Out-Null }
    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

    Compress-Archive -Path (Join-Path $stage $name) -DestinationPath $zipPath -CompressionLevel Optimal

    $size = (Get-Item -LiteralPath $zipPath).Length
    Write-Output ''
    Write-Output ("打包完成: {0}" -f $zipPath)
    Write-Output ("版本: {0}    大小: {1:N0} KB" -f $Version, ($size / 1KB))
    Write-Output ''
    Write-Output '包内文件:'
    Compress-Archive -Path (Join-Path $stage $name) -DestinationPath $zipPath -Update
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $archive.Entries | Sort-Object FullName | ForEach-Object {
            Write-Output ("  {0,8:N1} KB  {1}" -f ($_.Length / 1KB), $_.FullName)
        }
    } finally {
        $archive.Dispose()
    }
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}