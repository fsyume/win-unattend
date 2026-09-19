@echo off
rem ============================================================================
rem  iVentoy file-injection payload - runs inside the ISO's WinPE
rem ============================================================================
rem  Pack the CONTENTS of <iVentoy>\user\injection\ into ONE archive (.7z),
rem  then set that archive as the ISO's "Injection File" in iVentoy.
rem  iVentoy unpacks it into X:\ before winpeshl.exe runs, i.e. before
rem  setup.exe starts, and calls X:\VentoyAutoRun.bat automatically.
rem
rem  Two jobs:
rem    1. load NIC drivers into this WinPE so iVentoy can mount the ISO over
rem       the network - this is what prevents the "missing driver" error
rem    2. leave a diagnostic trail, because when PXE Windows deployment fails
rem       the reason is almost always "no NIC driver in boot.wim"
rem
rem  Output also goes to X:\VentoyAutoRun.log (iVentoy captures it too).
rem  This file must stay ASCII-only.
rem ============================================================================

setlocal enabledelayedexpansion
set "LOG=X:\VentoyAutoRun.log"

call :log "=== VentoyAutoRun begin ==="

rem --- firmware mode: 1 = BIOS, 2 = UEFI --------------------------------------
set "FW=unknown"
for /f "tokens=3" %%a in ('reg query "HKLM\SYSTEM\CurrentControlSet\Control" /v PEFirmwareType 2^>nul ^| find /i "PEFirmwareType"') do set "FW=%%a"
call :log "PEFirmwareType=%FW%  (1=BIOS, 2=UEFI)"

rem --- NIC drivers -----------------------------------------------------------
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

rem --- diagnostics -----------------------------------------------------------
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
