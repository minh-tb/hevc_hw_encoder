@echo off
set XILINXD_LICENSE_FILE=C:\Users\Admin\.Xilinx\Xilinx.lic
set VIVADO_BAT=D:\Xilinx\2026.1\Vivado\bin\vivado.bat

if not exist "%VIVADO_BAT%" (
    echo [ERROR] Vivado executable not found at: %VIVADO_BAT%
    exit /b 1
)

echo =================================================================
echo  Launching HEVC Hardware Encoder Vivado Synthesis Flow
echo  Script: synth/synth_vivado.tcl
echo  License: %XILINXD_LICENSE_FILE%
echo =================================================================

"%VIVADO_BAT%" -mode batch -source synth/synth_vivado.tcl -log synth/vivado_synth.log -journal synth/vivado_synth.jou
