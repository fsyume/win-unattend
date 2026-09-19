@echo off
rem ============================================================================
rem  首次登录时运行：把驱动总裁整包逐文件取回本地，然后启动它
rem ============================================================================
rem  由 unattend.xml 里的 FirstLogonCommands 调用。
rem
rem  为什么要「逐文件」而不是下载一个压缩包：
rem  iVentoy 的 HTTP 是静态文件服务，只能按文件取，不能取目录，
rem  也没有目录列表。所以清单（drvceo_files.txt）在服务器侧预先列好，
rem  本脚本按清单一个个拉回来，并保持原来的目录结构。
rem
rem  【编码要求】不要加 BOM，且运行时会打印的字符串一律保持英文。
rem  cmd.exe 按系统 OEM 代码页解析 .cmd/.bat，UTF-8 中文在控制台和日志里
rem  会变成乱码；加 BOM 更会让第一行直接报错。中文只放在 rem 注释里。
rem
rem  用法:
rem      install-drivers.cmd <清单URL> <驱动包根URL>
rem  例如:
rem      install-drivers.cmd ^
rem        http://192.168.10.226:16000/user/deploy/drvceo_files.txt ^
rem        http://192.168.10.226:16000/user/deploy/tool/Drvceo_Win10_Win11_x64_Lite
rem
rem  日志: C:\Windows\Temp\install-drivers.log
rem  目标: C:\DrvCeo\  （DrvCeo.exe 就跑在这里，路径短、无空格、无中文）
rem  本脚本退出后仍保留在 C:\Windows\Temp\ 下，现场可以手动重跑。
rem
rem  【想改成全静默】不要去猜参数，官方文档在同目录 Res\Cmdline\zh_cn.txt：
rem      -a        自动检测并安装驱动（部署环境无需加参数将自动安装）
rem      Silence   在 Drvceo.ini 的 [DrvCeoSet] 节下写 Silence=on，
rem                会隐藏软件窗体，运行和安装驱动时没有任何窗体
rem  本脚本默认【不加参数】，保留图形界面由现场人员确认。
rem ============================================================================

setlocal enabledelayedexpansion

set "LOG=C:\Windows\Temp\install-drivers.log"
set "DEST=C:\DrvCeo"
set "TMPD=C:\Windows\Temp"
set "LIST=%TMPD%\drvceo_files.txt"

set "LISTURL=%~1"
set "BASEURL=%~2"

if "%LISTURL%"=="" goto usage
if "%BASEURL%"=="" goto usage

call :log "=== install-drivers begin ==="
call :log "manifest = %LISTURL%"
call :log "base     = %BASEURL%"
call :log "dest     = %DEST%"

if not exist "%DEST%" mkdir "%DEST%"

rem ---- 1. 取清单（重试，顺便起到等待网络就绪的作用） ----
set /a tries=0
:getlist
set /a tries+=1
call :log "fetch manifest, attempt %tries% ..."
curl -sSL --connect-timeout 10 --max-time 120 -o "%LIST%" "%LISTURL%" 2>>"%LOG%"

set "lsz=0"
if exist "%LIST%" for %%i in ("%LIST%") do set "lsz=%%~zi"
if !lsz! GTR 100 goto listok

call :log "manifest fetch failed or too small"
if %tries% GEQ 5 goto failed
timeout /t 10 /nobreak >nul
goto getlist

:listok
call :log "manifest OK"

rem ---- 2. 按清单逐文件下载，保持目录结构 ----
set /a ok=0
set /a bad=0
for /f "usebackq delims=" %%L in ("%LIST%") do (
    set "rel=%%L"
    rem URL 用正斜杠，本地路径要换成反斜杠
    set "rel=!rel:/=\!"
    set "out=%DEST%\!rel!"

    rem 先建目录
    for %%D in ("!out!") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>nul

    curl -sSL --retry 2 --connect-timeout 10 --max-time 600 -o "!out!" "%BASEURL%/%%L" 2>>"%LOG%"

    set "fsz=0"
    if exist "!out!" for %%S in ("!out!") do set "fsz=%%~zS"
    if !fsz! GTR 0 (
        set /a ok+=1
    ) else (
        set /a bad+=1
        call :log "MISSING or EMPTY: !rel!"
    )
)
call :log "download finished: ok=!ok! bad=!bad!"

rem ---- 3. 启动驱动总裁 ----
rem 不加参数 = 保留图形界面，由现场人员确认后安装
rem 想全自动：在 Drvceo.ini 的 [DrvCeoSet] 节加 Silence=on，或给这里加 -a
if not exist "%DEST%\DrvCeo.exe" (
    call :log "!! %DEST%\DrvCeo.exe not found, abort"
    goto failed
)
if !bad! GTR 0 call :log "!! some files failed, DrvCeo may not run correctly"

call :log "launching DrvCeo.exe"
start "" "%DEST%\DrvCeo.exe"
call :log "installer launched, script exits"
call :log "=== install-drivers end ==="
timeout /t 8 /nobreak >nul
exit /b 0

:usage
echo Usage: %~nx0 ^<manifest-url^> ^<package-base-url^>
echo Example:
echo   %~nx0 http://192.168.10.226:16000/user/deploy/drvceo_files.txt http://192.168.10.226:16000/user/deploy/tool/Drvceo_Win10_Win11_x64_Lite
pause
exit /b 1

:failed
call :log "!! failed. Check that iVentoy is running and that the files exist"
call :log "!! under ^<iVentoy^>\user\deploy\"
echo.
echo Failed. See %LOG%
pause
exit /b 1

:log
echo [%date% %time%] %~1>>"%LOG%"
echo [%date% %time%] %~1
goto :eof
