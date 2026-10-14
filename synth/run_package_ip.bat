@echo off
set XILINXD_LICENSE_FILE=C:\Users\Admin\.Xilinx\Xilinx.lic
set VIVADO_BAT=D:\Xilinx\2026.1\Vivado\bin\vivado.bat

if not exist "%VIVADO_BAT%" (
    echo [ERROR] Vivado executable not found at: %VIVADO_BAT%
    exit /b 1
)

echo =================================================================
echo  Packaging HEVC Hardware Video Encoder IP Core
echo  Script: synth/package_ip.tcl
echo =================================================================

"%VIVADO_BAT%" -mode batch -source synth/package_ip.tcl -log synth/vivado_package.log -journal synth/vivado_package.jou
if %ERRORLEVEL% neq 0 (
    echo [ERROR] IP Packaging failed with exit code %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

echo =================================================================
echo  IP packaging finished successfully.
echo  Output: ip_repo/hevc_encoder_v1_0/component.xml
echo =================================================================
