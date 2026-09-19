@echo off
rem ============================================================================
rem  首次登录时运行：从 iVentoy 服务器取回驱动总裁并启动它
rem ============================================================================
rem  由 unattend.xml 里的 FirstLogonCommands 调用，参数是安装包的 HTTP 地址。
rem
rem  【编码要求】本文件不要加 BOM，且运行时会打印的字符串一律保持英文。
rem  cmd.exe 按系统 OEM 代码页解析 .cmd/.bat，UTF-8 的中文在控制台和日志里
rem  会变成乱码；而加 BOM 会让第一行直接报错。所以中文只放在 rem 注释里。
rem
rem  用法:
rem      install-drivers.cmd <安装包URL>
rem  例如:
rem      install-drivers.cmd http://192.168.10.226:16000/user/deploy/DrvCeoSetup.exe
rem
rem  日志: C:\Windows\Temp\install-drivers.log
rem  本脚本退出后仍保留在 C:\Windows\Temp\ 下，现场可以再手动跑一次。
rem ============================================================================

set "LOG=C:\Windows\Temp\install-drivers.log"
set "URL=%~1"

if "%URL%"=="" (
    echo Usage: %~nx0 ^<package-url^>
    echo Example: %~nx0 http://192.168.10.226:16000/user/deploy/DrvCeoSetup.exe
    pause
    exit /b 1
)

rem 从 URL 末尾取出文件名，统一落到 C:\Windows\Temp\
rem 注意：cmd 不把正斜杠当路径分隔符，所以先把 / 换成 \
for %%i in ("%URL:/=\%") do set "PKG=C:\Windows\Temp\%%~nxi"

call :log "=== install-drivers begin ==="
call :log "URL = %URL%"
call :log "destination = %PKG%"

rem ---- 1. 下载安装包（失败重试，顺便起到等待网络就绪的作用） ----
set /a tries=0
:download
set /a tries+=1
call :log "download attempt %tries% ..."
curl -L --retry 2 --connect-timeout 10 --max-time 900 -o "%PKG%" "%URL%" 2>>"%LOG%"

rem 小于 1MB 视为下载不完整（正常安装包是几十 MB）
set "ok="
if exist "%PKG%" for %%i in ("%PKG%") do if %%~zi GTR 1000000 set "ok=1"
if defined ok goto downloaded

call :log "download failed or file too small"
if %tries% GEQ 5 goto failed
timeout /t 10 /nobreak >nul
goto download

:downloaded
call :log "download OK"

rem ---- 2. 启动安装向导 ----
rem 这里【不加 /S】：保留图形界面，由现场人员确认后再装
rem 用 start 让安装程序独立运行，本脚本立即退出，不拖住首次登录
start "" "%PKG%"
call :log "installer launched, script exits"
call :log "=== install-drivers end ==="
rem 留几秒让现场看到结果，窗口随后自动关闭
timeout /t 8 /nobreak >nul
exit /b 0

:failed
call :log "!! download failed. Check that iVentoy is running and that"
call :log "!! <iVentoy>\user\deploy\ contains the installer package."
echo.
echo Download failed. See %LOG%
pause
exit /b 1

:log
echo [%date% %time%] %~1>>"%LOG%"
echo [%date% %time%] %~1
goto :eof
