# Definitional proc to organize widgets for parameters.
proc init_gui { IPINST } {
  ipgui::add_param $IPINST -name "Component_Name"
  #Adding Page
  set Page_0 [ipgui::add_page $IPINST -name "Page 0"]
  ipgui::add_param $IPINST -name "BASE_QP" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_M_AXIS_BITSTREAM_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_M_AXI_MEM_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_M_AXI_MEM_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_M_AXI_MEM_ID_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXIS_VIDEO_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_LITE_ADDR_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "C_S_AXI_LITE_DATA_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FRAME_HEIGHT" -parent ${Page_0}
  ipgui::add_param $IPINST -name "FRAME_WIDTH" -parent ${Page_0}
  ipgui::add_param $IPINST -name "GOP_STRUCTURE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "RC_ENABLE" -parent ${Page_0}
  ipgui::add_param $IPINST -name "TARGET_BITRATE_KBPS" -parent ${Page_0}


}

proc update_PARAM_VALUE.BASE_QP { PARAM_VALUE.BASE_QP } {
	# Procedure called to update BASE_QP when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.BASE_QP { PARAM_VALUE.BASE_QP } {
	# Procedure called to validate BASE_QP
	return true
}

proc update_PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH { PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH } {
	# Procedure called to update C_M_AXIS_BITSTREAM_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH { PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH } {
	# Procedure called to validate C_M_AXIS_BITSTREAM_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH { PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH } {
	# Procedure called to update C_M_AXI_MEM_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH { PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH } {
	# Procedure called to validate C_M_AXI_MEM_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH { PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH } {
	# Procedure called to update C_M_AXI_MEM_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH { PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH } {
	# Procedure called to validate C_M_AXI_MEM_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH { PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH } {
	# Procedure called to update C_M_AXI_MEM_ID_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH { PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH } {
	# Procedure called to validate C_M_AXI_MEM_ID_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH { PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH } {
	# Procedure called to update C_S_AXIS_VIDEO_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH { PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH } {
	# Procedure called to validate C_S_AXIS_VIDEO_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH } {
	# Procedure called to update C_S_AXI_LITE_ADDR_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH { PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH } {
	# Procedure called to validate C_S_AXI_LITE_ADDR_WIDTH
	return true
}

proc update_PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH { PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH } {
	# Procedure called to update C_S_AXI_LITE_DATA_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH { PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH } {
	# Procedure called to validate C_S_AXI_LITE_DATA_WIDTH
	return true
}

proc update_PARAM_VALUE.FRAME_HEIGHT { PARAM_VALUE.FRAME_HEIGHT } {
	# Procedure called to update FRAME_HEIGHT when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FRAME_HEIGHT { PARAM_VALUE.FRAME_HEIGHT } {
	# Procedure called to validate FRAME_HEIGHT
	return true
}

proc update_PARAM_VALUE.FRAME_WIDTH { PARAM_VALUE.FRAME_WIDTH } {
	# Procedure called to update FRAME_WIDTH when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.FRAME_WIDTH { PARAM_VALUE.FRAME_WIDTH } {
	# Procedure called to validate FRAME_WIDTH
	return true
}

proc update_PARAM_VALUE.GOP_STRUCTURE { PARAM_VALUE.GOP_STRUCTURE } {
	# Procedure called to update GOP_STRUCTURE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.GOP_STRUCTURE { PARAM_VALUE.GOP_STRUCTURE } {
	# Procedure called to validate GOP_STRUCTURE
	return true
}

proc update_PARAM_VALUE.RC_ENABLE { PARAM_VALUE.RC_ENABLE } {
	# Procedure called to update RC_ENABLE when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.RC_ENABLE { PARAM_VALUE.RC_ENABLE } {
	# Procedure called to validate RC_ENABLE
	return true
}

proc update_PARAM_VALUE.TARGET_BITRATE_KBPS { PARAM_VALUE.TARGET_BITRATE_KBPS } {
	# Procedure called to update TARGET_BITRATE_KBPS when any of the dependent parameters in the arguments change
}

proc validate_PARAM_VALUE.TARGET_BITRATE_KBPS { PARAM_VALUE.TARGET_BITRATE_KBPS } {
	# Procedure called to validate TARGET_BITRATE_KBPS
	return true
}


proc update_MODELPARAM_VALUE.FRAME_WIDTH { MODELPARAM_VALUE.FRAME_WIDTH PARAM_VALUE.FRAME_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FRAME_WIDTH}] ${MODELPARAM_VALUE.FRAME_WIDTH}
}

proc update_MODELPARAM_VALUE.FRAME_HEIGHT { MODELPARAM_VALUE.FRAME_HEIGHT PARAM_VALUE.FRAME_HEIGHT } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.FRAME_HEIGHT}] ${MODELPARAM_VALUE.FRAME_HEIGHT}
}

proc update_MODELPARAM_VALUE.GOP_STRUCTURE { MODELPARAM_VALUE.GOP_STRUCTURE PARAM_VALUE.GOP_STRUCTURE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.GOP_STRUCTURE}] ${MODELPARAM_VALUE.GOP_STRUCTURE}
}

proc update_MODELPARAM_VALUE.BASE_QP { MODELPARAM_VALUE.BASE_QP PARAM_VALUE.BASE_QP } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.BASE_QP}] ${MODELPARAM_VALUE.BASE_QP}
}

proc update_MODELPARAM_VALUE.RC_ENABLE { MODELPARAM_VALUE.RC_ENABLE PARAM_VALUE.RC_ENABLE } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.RC_ENABLE}] ${MODELPARAM_VALUE.RC_ENABLE}
}

proc update_MODELPARAM_VALUE.TARGET_BITRATE_KBPS { MODELPARAM_VALUE.TARGET_BITRATE_KBPS PARAM_VALUE.TARGET_BITRATE_KBPS } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.TARGET_BITRATE_KBPS}] ${MODELPARAM_VALUE.TARGET_BITRATE_KBPS}
}

proc update_MODELPARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_LITE_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH { MODELPARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_S_AXI_LITE_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH { MODELPARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH}] ${MODELPARAM_VALUE.C_S_AXIS_VIDEO_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH { MODELPARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH}] ${MODELPARAM_VALUE.C_M_AXIS_BITSTREAM_DATA_WIDTH}
}

proc update_MODELPARAM_VALUE.C_M_AXI_MEM_ID_WIDTH { MODELPARAM_VALUE.C_M_AXI_MEM_ID_WIDTH PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_M_AXI_MEM_ID_WIDTH}] ${MODELPARAM_VALUE.C_M_AXI_MEM_ID_WIDTH}
}

proc update_MODELPARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH { MODELPARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH}] ${MODELPARAM_VALUE.C_M_AXI_MEM_ADDR_WIDTH}
}

proc update_MODELPARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH { MODELPARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH } {
	# Procedure called to set VHDL generic/Verilog parameter value(s) based on TCL parameter value
	set_property value [get_property value ${PARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH}] ${MODELPARAM_VALUE.C_M_AXI_MEM_DATA_WIDTH}
}

