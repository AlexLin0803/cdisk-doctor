@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if %errorLevel% neq 0 (
    echo.
    echo   [!] 需要管理员权限。请右键本文件 - "以管理员身份运行"。
    echo.
    pause
    exit /b 1
)

echo.
echo   ============================================
echo     CDiskDoctor - C 盘空间医生
echo   ============================================
echo.
echo   1. 分析并生成报告（只读，安全）
echo   2. 预览可清理的空间（不删除任何文件）
echo   3. 执行安全清理
echo   4. 迁移大目录到其他盘
echo   5. 迁移分析（哪些能搬走）
echo   6. 系统级占用检查（页面文件 / 休眠文件）
echo   7. 帮助
echo.
set /p CHOICE=  请选择 [1-7]:

if "%CHOICE%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode Analyze -OpenReport
) else if "%CHOICE%"=="2" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode Clean -DryRun
) else if "%CHOICE%"=="3" (
    echo.
    echo   即将清理：临时文件、更新缓存、浏览器缓存、回收站等。
    echo   不会动你的文档、桌面、下载。
    echo.
    set /p CONFIRM=  确认执行？(Y/N):
    if /i "%CONFIRM%"=="Y" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode Clean -Apply
    )
) else if "%CHOICE%"=="4" (
    echo.
    set /p SRCPATH=  要迁移的目录（例如 C:\Users\你的用户名\AppData\Roaming\SomeApp）:
    set /p DSTPATH=  目标根目录（例如 D:\MovedData）:
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode Migrate -Path "%SRCPATH%" -Target "%DSTPATH%"
) else if "%CHOICE%"=="5" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\Classify.ps1" -MinMB 200 -OpenReport
) else if "%CHOICE%"=="6" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode System
    echo.
    echo   提示：C 盘页面文件过大时，运行下面这条命令可迁到其他盘（需重启生效）：
    echo     powershell -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode System -Apply
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "src\CDiskDoctor.ps1" -Mode Help
)

echo.
pause