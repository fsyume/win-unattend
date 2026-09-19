@echo off
rem ============================================================================
rem  首次登录时运行：把整个 tool 文件夹取回本地，然后跑驱动总裁的 start.bat
rem ============================================================================
rem  由 unattend.xml 里的 FirstLogonCommands 调用。
rem
rem  为什么要「逐文件」而不是下载一个压缩包：
rem  iVentoy 的 HTTP 是静态文件服务，只能按文件取，不能取目录，
rem  也没有目录列表。所以清单（tool_files.txt）在服务器侧预先列好，
rem  本脚本按清单一个个拉回来，并保持原来的目录结构。
rem
rem  【清单必须只含 ASCII 路径】
rem  cmd.exe 按系统 OEM 代码页解析，清单里若有中文/空格，客户端会生成
rem  乱码文件名甚至下载失败。因此清单里的路径只允许 A-Z a-z 0-9 . _ - /
rem  含其它字符的文件请先改成 ASCII 名字，再重新生成清单。
rem  生成命令见 user/deploy/README.md。
rem
rem  【编码要求】本文件不要加 BOM，运行时会打印的字符串一律保持英文。
rem  中文只放在 rem 注释里。
rem
rem  用法:
rem      install-drivers.cmd <清单URL> <tool根URL>
rem  例如:
rem      install-drivers.cmd ^
rem        http://192.168.10.226:16000/user/deploy/tool_files.txt ^
rem        http://192.168.10.226:16000/user/deploy/tool
rem
rem  日志: C:\Windows\Temp\install-drivers.log
rem  目标: C:\tool\
rem  本脚本退出后仍保留在 C:\Windows\Temp\ 下，现场可以手动重跑。
rem ============================================================================

setlocal enabledelayedexpansion

set "LOG=C:\Windows\Temp\install-drivers.log"
set "DEST=C:\tool"
set "TMPD=C:\Windows\Temp"
set "LIST=%TMPD%\tool_files.txt"
set "CEODIR=%DEST%\Drvceo_Win10_Win11_x64_Lite"

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
set /a seen=0

for /f "usebackq delims=" %%L in ("%LIST%") do (
    set "rel=%%L"
    rem URL 用正斜杠，本地路径要换成反斜杠
    set "rel=!rel:/=\!"
    set "out=%DEST%\!rel!"

    rem 先建父目录
    for %%D in ("!out!") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>nul

    curl -sSL --retry 2 --connect-timeout 10 --max-time 900 -o "!out!" "%BASEURL%/%%L" 2>>"%LOG%"

    set "fsz=0"
    if exist "!out!" for %%S in ("!out!") do set "fsz=%%~zS"
    if !fsz! GTR 0 (
        set /a ok+=1
        >>"%LOG%" echo [%date% %time%] ok: !rel!
    ) else (
        set /a bad+=1
        call :log "MISSING or EMPTY: !rel!"
    )

    rem 每 20 个在控制台报一次进度，避免看起来像卡死
    set /a seen+=1
    set /a mod=seen %% 20
    if !mod! EQU 0 echo   progress: !seen! files ...
)
call :log "download finished: ok=!ok! bad=!bad!"

rem ---- 3. 跑驱动总裁的 start.bat ----
rem start.bat 的内容是 ".\DrvCeo.exe /a"，用的是【相对路径】，
rem 所以必须把工作目录设在它所在的那个文件夹，否则 .\DrvCeo.exe 找不到。
rem start 的 /D 参数就是干这个的。
rem 用 start 让它独立运行，本脚本立即退出，不拖住首次登录（第一步的下载
rem 会发生在桌面出现之前，这一步之后桌面才会出来）。
if not exist "%CEODIR%\start.bat" (
    call :log "!! %CEODIR%\start.bat not found, abort"
    goto failed
)
if !bad! GTR 0 call :log "!! some files failed, the tool folder may be incomplete"

call :log "launching start.bat in %CEODIR%"
start "" /D "%CEODIR%" cmd /c start.bat
call :log "launched, script exits"
call :log "=== install-drivers end ==="
timeout /t 8 /nobreak >nul
exit /b 0

:usage
echo Usage: %~nx0 ^<manifest-url^> ^<tool-base-url^>
echo Example:
echo   %~nx0 http://192.168.10.226:16000/user/deploy/tool_files.txt http://192.168.10.226:16000/user/deploy/tool
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
>>"%LOG%" echo [%date% %time%] %~1
echo [%date% %time%] %~1
goto :eof
