@echo off
setlocal enabledelayedexpansion
title DailyCheckin - 安装开机自动同步

rem ====================================================================
rem  把 sync-token.ps1 设为「开机后自动运行一次」
rem
rem  原理：注册一个计划任务，登录时触发，静默调用 sync-token.ps1。
rem  这样你每天开电脑，云端 Secret 就自动更新成最新的 token。
rem
rem  直接双击运行即可（会自动请求管理员权限）。
rem ====================================================================

cd /d "%~dp0"
set "HERE=%~dp0"
set "HERE=%HERE:~0,-1%"
set "PS1=%HERE%\sync-token.ps1"
set "TASKNAME=DailyCheckin-SyncToken"

rem ---------------- 自动提权 ----------------
net session >nul 2>&1
if errorlevel 1 (
    echo.
    echo   需要管理员权限来创建计划任务，正在请求提升...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

rem ---------------- 检查脚本存在 ----------------
if not exist "%PS1%" (
    echo.
    echo   [错误] 未找到 sync-token.ps1
    echo   期望路径: %PS1%
    echo.
    pause
    exit /b 1
)

rem ---------------- 前置检查：GitHub CLI ----------------
echo.
echo ====================================================================
echo              安装：开机自动同步 Token 到 GitHub
echo ====================================================================
echo   脚本路径 : %PS1%
echo   任务名称 : %TASKNAME%
echo --------------------------------------------------------------------
echo.

where gh >nul 2>&1
if errorlevel 1 (
    if not defined GH_PAT (
        echo   [提醒] 未检测到 GitHub CLI，也未设置 GH_PAT 环境变量。
        echo.
        echo   推荐先执行以下两步，再运行本安装脚本：
        echo     winget install --id GitHub.cli
        echo     gh auth login
        echo.
        echo   否则同步会失败。是否仍要继续安装计划任务？
        echo.
        choice /c YN /m "  继续安装 (Y=是 / N=退出)"
        if errorlevel 2 exit /b 0
    )
)

rem ---------------- 创建计划任务 ----------------
rem 触发：用户登录时
rem 动作：无窗口运行 PowerShell 脚本
echo   正在创建计划任务...

schtasks /Query /TN "%TASKNAME%" >nul 2>&1
if not errorlevel 1 (
    echo   检测到已存在同名任务，先删除旧的...
    schtasks /Delete /TN "%TASKNAME%" /F >nul 2>&1
)

set "PSARGS=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""%PS1%"" -Quiet"

schtasks /Create ^
    /TN "%TASKNAME%" ^
    /TR "powershell.exe %PSARGS%" ^
    /SC ONLOGON ^
    /RL HIGHEST ^
    /F

if errorlevel 1 (
    echo.
    echo   [失败] 计划任务创建失败。
    echo.
    pause
    exit /b 1
)

echo.
echo   [成功] 计划任务已创建。
echo.

rem ---------------- 询问是否立即执行一次 ----------------
echo --------------------------------------------------------------------
choice /c YN /m "  是否立即执行一次同步，验证配置是否正确 (Y=是 / N=否)"
if errorlevel 2 goto :done

echo.
echo   正在执行同步...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
echo.
echo   同步完成。详细日志见: %HERE%\sync-token.log

:done
echo.
echo ====================================================================
echo   安装完成
echo --------------------------------------------------------------------
echo   以后每次开机登录，会自动把最新 token 同步到 GitHub。
echo.
echo   常用操作：
echo     查看任务 : schtasks /Query /TN "%TASKNAME%" /V /FO LIST
echo     手动执行 : schtasks /Run /TN "%TASKNAME%"
echo     删除任务 : schtasks /Delete /TN "%TASKNAME%" /F
echo     查看日志 : type "%HERE%\sync-token.log"
echo ====================================================================
echo.
pause
