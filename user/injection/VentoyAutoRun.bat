@echo off
rem ============================================================================
rem  iVentoy 文件注入负载：在 ISO 的 WinPE 环境里执行
rem ============================================================================
rem  把 <iVentoy>\user\injection\ 里的【内容】打成一个压缩包（.7z），
rem  然后在 iVentoy 里把它设为该 ISO 的「注入文件」。
rem  iVentoy 会在 winpeshl.exe 运行之前把它解压到 X:\，
rem  也就是在 setup.exe 启动之前，并自动调用 X:\VentoyAutoRun.bat。
rem
rem  【编码要求】本文件不要加 BOM。
rem  cmd.exe 遇到 BOM 会把第一行读成 'iVentoy @echo' 之类的乱码并直接报错。
rem  因此这里的中文只出现在 rem 注释行里；真正会打印到控制台和日志的
rem  字符串一律保持英文，因为 WinPE 的控制台代码页不是中文，
rem  中文输出会变成乱码。
rem
rem  两个职责：
rem    1. 把网卡驱动装进当前 WinPE，好让 iVentoy 能通过网络挂载 ISO。
rem       这就是用来防止「缺少计算机所需的介质驱动程序」报错的关键动作。
rem    2. 留下诊断线索：PXE 方式装 Windows 失败时，原因几乎总是
rem       「boot.wim 里没有对应网卡的驱动」。
rem
rem  输出同时写入 X:\VentoyAutoRun.log（iVentoy 也会捕获该日志）。
rem ============================================================================

setlocal enabledelayedexpansion
set "LOG=X:\VentoyAutoRun.log"

call :log "=== VentoyAutoRun begin ==="

rem --- 固件模式：1 = BIOS，2 = UEFI -------------------------------------------
set "FW=unknown"
for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v PEFirmwareType 2^>nul ^| find /i "PEFirmwareType"') do set "FW=%%a"
call :log "PEFirmwareType=%FW%  (1=BIOS, 2=UEFI)"

rem --- 网卡驱动 ---------------------------------------------------------------
if exist X:\drivers (
    call :log "X:\drivers found - loading into WinPE"
    for /f "delims=" %%i in ('dir /b /s "X:\drivers\*.inf" 2^>nul') do (
        call :log "  drvload %%i"
        drvload "%%i" >>"%LOG%" 2>&1
    )
    call :log "pnputil /add-driver X:\drivers\*.inf /subdirs /install"
    pnputil /add-driver "X:\drivers\*.inf" /subdirs /install >>"%LOG%" 2>&1
) else (
    call :log "X:\drivers NOT FOUND - the injection archive has no drivers folder."
    call :log "If setup later reports a missing driver, this is why."
)

rem --- 诊断信息 ---------------------------------------------------------------
call :log "--- ipconfig /all ---"
ipconfig /all >>"%LOG%" 2>&1

call :log "--- network devices visible to WinPE ---"
powershell -NoProfile -Command "Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Select-Object Status,FriendlyName,InstanceId | Format-Table -AutoSize | Out-String -Width 400" >>"%LOG%" 2>&1

call :log "--- disk inventory (check this before trusting the answer file) ---"
> X:\_dp.txt echo list disk
diskpart /s X:\_dp.txt >>"%LOG%" 2>&1

call :log "=== VentoyAutoRun end ==="
exit /b 0

:log
echo [%date% %time%] %~1>>"%LOG%"
echo [%date% %time%] %~1
goto :eof
