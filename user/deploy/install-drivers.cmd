@echo off
rem ============================================================================
rem  First-logon task: pull the whole tool folder from the iVentoy server,
rem  then run the driver start.bat.
rem
rem  Called by FirstLogonCommands in unattend.xml.
rem
rem  ---------------------------------------------------------------------------
rem  THIS FILE MUST STAY 100%% ASCII. Do not add non-ASCII characters.
rem
rem  Two reasons, both learned the hard way:
rem    1. cmd.exe parses .bat/.cmd using the system OEM code page. Non-ASCII
rem       in comments can make it lose its place when resolving goto/call,
rem       which is a classic source of garbled output in batch files.
rem    2. Anything echoed to the console or the log is shown using whatever
rem       code page that console happens to use, so non-ASCII output is a
rem       gamble. %date% is avoided for exactly this reason: on a zh-CN
rem       system it expands to something like "2026/09/20 <Chinese weekday>",
rem       so every log line would start with characters that may not render.
rem       %time% is used instead - it is always plain ASCII.
rem
rem  Chinese documentation lives in user/deploy/README.md instead.
rem  ---------------------------------------------------------------------------
rem
rem  Why a per-file download rather than one archive:
rem  iVentoy's HTTP is a static file service. It serves files, not
rem  directories, and there is no directory listing. So a manifest is
rem  prepared on the server and this script walks it, recreating the tree.
rem
rem  The manifest must also be ASCII-only: cmd.exe interprets it through the
rem  OEM code page, so a path with Chinese characters or spaces becomes a
rem  mojibake filename or a failed download.
rem
rem  Usage:
rem      install-drivers.cmd <manifest-url> <tool-base-url>
rem  Example:
rem      install-drivers.cmd http://192.168.10.226:16000/user/deploy/tool_files.txt http://192.168.10.226:16000/user/deploy/tool
rem
rem  Log   : C:\Windows\Temp\install-drivers.log
rem  Target: C:\tool\
rem  This script stays in C:\Windows\Temp\ so it can be re-run by hand.
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

rem ---- 1. Fetch the manifest (with retries; also waits for the network) ----
set /a tries=0
:getlist
set /a tries+=1
call :log "fetch manifest, attempt %tries%"
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

rem ---- 2. Walk the manifest, keep the directory structure ----
set /a ok=0
set /a bad=0
set /a seen=0

for /f "usebackq delims=" %%L in ("%LIST%") do (
    set "rel=%%L"
    rem URLs use forward slashes; the local path needs backslashes
    set "rel=!rel:/=\!"
    set "out=%DEST%\!rel!"

    rem create the parent directory first
    for %%D in ("!out!") do if not exist "%%~dpD" mkdir "%%~dpD" >nul 2>nul

    curl -sSL --retry 2 --connect-timeout 10 --max-time 900 -o "!out!" "%BASEURL%/%%L" 2>>"%LOG%"

    set "fsz=0"
    if exist "!out!" for %%S in ("!out!") do set "fsz=%%~zS"
    if !fsz! GTR 0 (
        set /a ok+=1
        >>"%LOG%" echo [%time%] ok: !rel!
    ) else (
        set /a bad+=1
        call :log "MISSING or EMPTY: !rel!"
    )

    rem report progress to the console every 20 files so it does not look hung
    set /a seen+=1
    set /a mod=seen %% 20
    if !mod! EQU 0 echo   progress: !seen! files
)
call :log "download finished: ok=!ok! bad=!bad!"

rem ---- 3. Run the driver start.bat ----
rem start.bat contains ".\DrvCeo.exe /a" - a RELATIVE path, so the working
rem directory must be its own folder or .\DrvCeo.exe will not be found.
rem start's /D switch sets that working directory.
rem /a is the vendor's own switch for automatic driver installation.
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
call :log "!! under the iVentoy user\deploy\ folder"
echo.
echo Failed. See %LOG%
pause
exit /b 1

:log
>>"%LOG%" echo [%time%] %~1
echo [%time%] %~1
goto :eof
