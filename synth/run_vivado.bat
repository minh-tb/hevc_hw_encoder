@echo off
setlocal enabledelayedexpansion

set XILINXD_LICENSE_FILE=C:\Users\Admin\.Xilinx\Xilinx.lic
set VIVADO_BAT=D:\Xilinx\2026.1\Vivado\bin\vivado.bat

if not exist "%VIVADO_BAT%" (
    echo [ERROR] Vivado executable not found at: %VIVADO_BAT%
    exit /b 1
)

set ACTION=%1
if "%ACTION%"=="" set ACTION=synth

echo =================================================================
echo  HEVC Hardware Video Encoder - Vivado Toolflow Manager
echo  Action:  %ACTION%
if defined VIVADO_PART (
    echo  Part:    %VIVADO_PART%
) else (
    echo  Part:    xczu19eg-ffvb1517-2-e (Default)
)
echo =================================================================

if /i "%ACTION%"=="package" (
    call synth\run_package_ip.bat
    exit /b !ERRORLEVEL!
)

if /i "%ACTION%"=="verify" (
    echo [RUN] Verifying IP Catalog instantiation...
    "%VIVADO_BAT%" -mode batch -source synth/verify_ip_catalog.tcl -log synth/vivado_verify.log -journal synth/vivado_verify.jou
    exit /b !ERRORLEVEL!
)

if /i "%ACTION%"=="synth" (
    echo [RUN] Running Out-of-Context Synthesis...
    "%VIVADO_BAT%" -mode batch -source synth/synth_vivado.tcl -log synth/vivado_synth.log -journal synth/vivado_synth.jou
    set SYNTH_ERR=!ERRORLEVEL!
    if !SYNTH_ERR! neq 0 (
        echo [ERROR] Synthesis failed with code !SYNTH_ERR!
        exit /b !SYNTH_ERR!
    )
    python synth/extract_vivado_results.py
    exit /b 0
)

if /i "%ACTION%"=="all" (
    echo [STEP 1/3] Packaging IP...
    call synth\run_package_ip.bat
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!

    echo [STEP 2/3] Verifying IP Catalog...
    "%VIVADO_BAT%" -mode batch -source synth/verify_ip_catalog.tcl -log synth/vivado_verify.log -journal synth/vivado_verify.jou
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!

    echo [STEP 3/3] Running Out-of-Context Synthesis...
    "%VIVADO_BAT%" -mode batch -source synth/synth_vivado.tcl -log synth/vivado_synth.log -journal synth/vivado_synth.jou
    if !ERRORLEVEL! neq 0 exit /b !ERRORLEVEL!

    python synth/extract_vivado_results.py
    exit /b 0
)

echo [ERROR] Unknown action "%ACTION%". Valid actions: synth, package, verify, all.
exit /b 1
