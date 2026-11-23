#==========================================================================================
# HEVC Hardware Encoder Dual-Tier UVM Verification Makefile
# Supports Siemens QuestaSim 2021.2_1 (tool=DEFAULT) & Cadence Xcelium (tool=Cadence)
#
# Usage (from uvm/ on asiclab Linux server):
#   source env.sh
#   cd sim
#
#   # Tier 1: Block-Level CABAC M-Coder (tb_uvm_cabac)
#   make compile_cabac
#   make vopt_run_cabac
#   make coverage_cabac
#
#   # Tier 2: SoC AXI Top + RAL + Bitstream (tb_uvm_axi_top)
#   make compile_axi
#   make vopt_run test_name=hevc_ral_audit_test
#   make vopt_run test_name=hevc_full_uvm_test
#   make coverage test_name=hevc_full_uvm_test
#
#   # Full Dual-Tier Regression & Merged UCDB Coverage
#   make regression
#
#   # Cadence Xcelium Flow
#   make compile_all tool=Cadence
#   make run test_name=hevc_full_uvm_test tool=Cadence
#==========================================================================================

HEVC_ROOT_DIR ?= $(abspath ../..)
HEVC_UVM_DIR  ?= $(abspath ..)

test_name       ?= hevc_full_uvm_test
cabac_test_name ?= cabac_uvm_test
cmd_args        ?=
tool            ?= DEFAULT

TOP_CABAC       = tb_uvm_cabac
VOPT_CABAC      = vopt_cabac
TOP_AXI         = tb_uvm_axi_top
VOPT_AXI        = vopt_axi_top
TOP             = $(TOP_AXI)
VOPT_TOP        = $(VOPT_AXI)

VSIM_CMD        = vsim
VOPT_CABAC_CMD  = vopt +acc $(TOP_CABAC) -o $(VOPT_CABAC) +designfile
VOPT_AXI_CMD    = vopt +acc $(TOP_AXI) -o $(VOPT_AXI) +designfile
VCOVER_CMD      = vcover

ifeq ($(tool),DEFAULT)
	VLOG_CMD = vlog -sv -timescale 1ns/1ps
	COV_OPT ?= +cover
else
	VLOG_CMD = xrun -c -uvm -sv -timescale 1ns/1ps
	COV_OPT ?=
endif

RTL_DIR     = $(HEVC_ROOT_DIR)/rtl
CABAC_DIR   = $(HEVC_UVM_DIR)/uvm_cabac
AXI_TOP_DIR = $(HEVC_UVM_DIR)/uvm_axi_top
AXI_VIP_DIR = $(AXI_TOP_DIR)/vip
AXI_ENV_DIR = $(AXI_TOP_DIR)/env
AXI_TST_DIR = $(AXI_TOP_DIR)/tests
SIM_DIR     = $(HEVC_UVM_DIR)/sim

RTL_FLAGS = +incdir+$(RTL_DIR)/common +incdir+$(RTL_DIR)/top

RTL_HDRS = \
	$(RTL_DIR)/common/parameter_pkg.vh \
	$(RTL_DIR)/common/hevc_interfaces.vh

# Exact 59 synthesizable RTL modules matching synth/synth_vivado.tcl (lines 43-103)
RTL_SRCS = \
	$(RTL_DIR)/common/axi_read_arbiter.v \
	$(RTL_DIR)/common/hadamard_satd_4x4.v \
	$(RTL_DIR)/entropy/bin_encoder.v \
	$(RTL_DIR)/entropy/cabac_enc_top.v \
	$(RTL_DIR)/entropy/coeff_buffer.v \
	$(RTL_DIR)/entropy/ctx_model_store.v \
	$(RTL_DIR)/entropy/param_set_writer.v \
	$(RTL_DIR)/entropy/range_coder.v \
	$(RTL_DIR)/entropy/syntax_coeff.v \
	$(RTL_DIR)/entropy/syntax_cu.v \
	$(RTL_DIR)/entropy/syntax_pred.v \
	$(RTL_DIR)/entropy/syntax_sao.v \
	$(RTL_DIR)/inloop_filters/boundary_strength.v \
	$(RTL_DIR)/inloop_filters/db_filter_chroma.v \
	$(RTL_DIR)/inloop_filters/db_filter_luma.v \
	$(RTL_DIR)/inloop_filters/deblock_top.v \
	$(RTL_DIR)/inloop_filters/sao_band_offset.v \
	$(RTL_DIR)/inloop_filters/sao_edge_offset.v \
	$(RTL_DIR)/inloop_filters/sao_stats.v \
	$(RTL_DIR)/inloop_filters/sao_top.v \
	$(RTL_DIR)/input_output/nal_writer.v \
	$(RTL_DIR)/inter/fme_search.v \
	$(RTL_DIR)/inter/hpel_filter_chroma.v \
	$(RTL_DIR)/inter/hpel_filter_luma.v \
	$(RTL_DIR)/inter/inter_pred_top.v \
	$(RTL_DIR)/inter/mc_unit.v \
	$(RTL_DIR)/inter/mvp_predictor.v \
	$(RTL_DIR)/inter/ref_frame_buffer.v \
	$(RTL_DIR)/inter/sad_4x4.v \
	$(RTL_DIR)/inter/mc_window_fetch.v \
	$(RTL_DIR)/inter/subpel_interpolation_core.v \
	$(RTL_DIR)/inter/tz_search.v \
	$(RTL_DIR)/intra/intra_angular.v \
	$(RTL_DIR)/intra/intra_dc.v \
	$(RTL_DIR)/intra/intra_planar.v \
	$(RTL_DIR)/intra/intra_rmd.v \
	$(RTL_DIR)/intra/intra_pred_top.v \
	$(RTL_DIR)/intra/ref_sample_filter.v \
	$(RTL_DIR)/partition/ctu_partitioner.v \
	$(RTL_DIR)/partition/ctu_raster_scan.v \
	$(RTL_DIR)/partition/mode_decision.v \
	$(RTL_DIR)/partition/pu_cu_splitter.v \
	$(RTL_DIR)/partition/rate_estimator.v \
	$(RTL_DIR)/quant/fwd_quant.v \
	$(RTL_DIR)/quant/inv_quant.v \
	$(RTL_DIR)/rate_control/lambda_calc.v \
	$(RTL_DIR)/rate_control/rate_controller.v \
	$(RTL_DIR)/recon/frame_store.v \
	$(RTL_DIR)/recon/recon_unit.v \
	$(RTL_DIR)/recon/residual_sub.v \
	$(RTL_DIR)/top/address_generator.v \
	$(RTL_DIR)/top/decoder_inloop_filters.v \
	$(RTL_DIR)/top/gop_controller.v \
	$(RTL_DIR)/top/hevc_encoder_top.v \
	$(RTL_DIR)/top/slice_controller.v \
	$(RTL_DIR)/transform/transform_1d_core.v \
	$(RTL_DIR)/transform/transpose_ram_32x32.v \
	$(RTL_DIR)/transform/dct_top.v \
	$(RTL_DIR)/top/hevc_encoder_axi_top.v

.PHONY: compile_all compile_cabac compile_axi lib cabac_rtl cabac_tb axi_rtl axi_tb \
        vopt_cabac vopt_axi vopt_run_cabac vopt_random_cabac vopt_gui_cabac \
        run_cabac coverage_cabac wave_cabac vis_run_cabac vopt_run vopt_random \
        vopt_gui run coverage wave vis_run regression clean help

ifeq ($(tool),DEFAULT)
compile_all: lib axi_rtl cabac_tb axi_tb vopt_cabac vopt_axi
compile_cabac: lib cabac_rtl cabac_tb vopt_cabac
compile_axi: lib axi_rtl axi_tb vopt_axi
else
compile_all: axi_rtl cabac_tb axi_tb
compile_cabac: cabac_rtl cabac_tb
compile_axi: axi_rtl axi_tb
endif

lib:
	@test -d work || vlib work

cabac_rtl:
	$(VLOG_CMD) $(COV_OPT) $(RTL_FLAGS) $(RTL_HDRS) $(RTL_DIR)/entropy/range_coder.v

cabac_tb:
	$(VLOG_CMD) +incdir+$(CABAC_DIR) $(CABAC_DIR)/cabac_if.sv
	$(VLOG_CMD) +incdir+$(CABAC_DIR) $(CABAC_DIR)/cabac_uvm_pkg.sv
	$(VLOG_CMD) +incdir+$(CABAC_DIR) $(CABAC_DIR)/tb_uvm_cabac.sv

axi_rtl:
	$(VLOG_CMD) $(COV_OPT) $(RTL_FLAGS) $(RTL_HDRS) $(RTL_SRCS)

axi_tb:
	$(VLOG_CMD) +incdir+$(AXI_VIP_DIR) $(AXI_VIP_DIR)/hevc_axi_if.sv
	$(VLOG_CMD) +incdir+$(AXI_VIP_DIR) $(AXI_VIP_DIR)/hevc_ral_pkg.sv
	$(VLOG_CMD) +incdir+$(AXI_VIP_DIR) $(AXI_VIP_DIR)/hevc_axi_vip_pkg.sv
	$(VLOG_CMD) +incdir+$(AXI_ENV_DIR) +incdir+$(AXI_VIP_DIR) $(AXI_ENV_DIR)/hevc_axi_env_pkg.sv
	$(VLOG_CMD) +incdir+$(AXI_TST_DIR) +incdir+$(AXI_ENV_DIR) +incdir+$(AXI_VIP_DIR) $(AXI_TST_DIR)/hevc_axi_tests_pkg.sv
	$(VLOG_CMD) +incdir+$(AXI_TOP_DIR) +incdir+$(AXI_TST_DIR) +incdir+$(AXI_ENV_DIR) +incdir+$(AXI_VIP_DIR) $(AXI_TOP_DIR)/tb_uvm_axi_top.sv

vopt_cabac:
	$(VOPT_CABAC_CMD)

vopt_axi:
	$(VOPT_AXI_CMD)

ifeq ($(tool),DEFAULT)
vopt_run_cabac:
	$(VSIM_CMD) -c $(VOPT_CABAC) -do sim.do +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

vopt_random_cabac:
	$(VSIM_CMD) -sv_seed random -c $(VOPT_CABAC) -do sim.do +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

vopt_gui_cabac:
	$(VSIM_CMD) $(VOPT_CABAC) +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

run_cabac:
	$(VSIM_CMD) -c $(TOP_CABAC) -do sim.do +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

coverage_cabac:
	rm -f cabac.ucdb
	$(VSIM_CMD) -c -sv_seed random -coverage $(VOPT_CABAC) -do "coverage save -onexit -testname $(cabac_test_name) cabac.ucdb; run -all; quit -f" +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

wave_cabac:
	$(VSIM_CMD) -voptargs="+acc" $(TOP_CABAC) +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

vis_run_cabac:
	$(VSIM_CMD) -c $(VOPT_CABAC) -do sim.do +UVM_TESTNAME=$(cabac_test_name) $(cmd_args) -qwavedb=+signal+class

vopt_run:
	$(VSIM_CMD) -c $(VOPT_AXI) -do sim.do +UVM_TESTNAME=$(test_name) $(cmd_args)

vopt_random:
	$(VSIM_CMD) -sv_seed random -c $(VOPT_AXI) -do sim.do +UVM_TESTNAME=$(test_name) $(cmd_args)

vopt_gui:
	$(VSIM_CMD) $(VOPT_AXI) +UVM_TESTNAME=$(test_name) $(cmd_args)

run:
	$(VSIM_CMD) -c $(TOP_AXI) -do sim.do +UVM_TESTNAME=$(test_name) $(cmd_args)

coverage:
	rm -f $(test_name).ucdb
	$(VSIM_CMD) -c -sv_seed random -coverage $(VOPT_AXI) -do "coverage save -onexit -testname $(test_name) $(test_name).ucdb; run -all; quit -f" +UVM_TESTNAME=$(test_name) $(cmd_args)

wave:
	$(VSIM_CMD) -voptargs="+acc" $(TOP_AXI) +UVM_TESTNAME=$(test_name) $(cmd_args)

vis_run:
	$(VSIM_CMD) -c $(VOPT_AXI) -do sim.do +UVM_TESTNAME=$(test_name) $(cmd_args) -qwavedb=+signal+class
else
vopt_run_cabac: run_cabac

vopt_random_cabac:
	xrun -uvm -sv -svseed random -top worklib.$(TOP_CABAC) +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

vopt_gui_cabac:
	xrun -gui -access +rwc -uvm -sv -top worklib.$(TOP_CABAC) +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

run_cabac:
	xrun -uvm -sv -top worklib.$(TOP_CABAC) +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

coverage_cabac:
	xrun -uvm -sv -top worklib.$(TOP_CABAC) -coverage all -covoverwrite -covtest cabac +UVM_TESTNAME=$(cabac_test_name) $(cmd_args)

wave_cabac: vopt_gui_cabac

vis_run_cabac: run_cabac

vopt_run: run

vopt_random:
	xrun -uvm -sv -svseed random -top worklib.$(TOP_AXI) +UVM_TESTNAME=$(test_name) $(cmd_args)

vopt_gui:
	xrun -gui -access +rwc -uvm -sv -top worklib.$(TOP_AXI) +UVM_TESTNAME=$(test_name) $(cmd_args)

run:
	xrun -uvm -sv -top worklib.$(TOP_AXI) +UVM_TESTNAME=$(test_name) $(cmd_args)

coverage:
	xrun -uvm -sv -top worklib.$(TOP_AXI) -coverage all -covoverwrite -covtest $(test_name) +UVM_TESTNAME=$(test_name) $(cmd_args)

wave: vopt_gui

vis_run: run
endif

regression:
	$(MAKE) compile_cabac tool=$(tool)
	$(MAKE) coverage_cabac tool=$(tool)
	$(MAKE) compile_axi tool=$(tool)
	$(MAKE) coverage test_name=hevc_ral_audit_test tool=$(tool)
	$(MAKE) coverage test_name=hevc_full_uvm_test tool=$(tool)
ifeq ($(tool),DEFAULT)
	$(VCOVER_CMD) merge hevc_uvm_merged.ucdb cabac.ucdb hevc_ral_audit_test.ucdb hevc_full_uvm_test.ucdb
	$(VCOVER_CMD) report -details hevc_uvm_merged.ucdb > cov_summary.log
else
	imc -execcmd "merge cov_work/scope/* -out hevc_uvm_merged -overwrite; load -run hevc_uvm_merged; report -details -metrics all -out cov_summary.log"
endif

clean:
	rm -rf *.wlf *.ucdb *.log *.bin *.yuv transcript work design.* xrun.* xcelium.d cov_work imc.* mdv.log qwave.db TraceDec.txt

help:
	@echo "HEVC Dual-Tier UVM Verification Targets (tool=$(tool)):"
	@echo "  compile_cabac     Compile Tier 1 CABAC RTL + UVM TB (+ vopt)"
	@echo "  vopt_run_cabac    Run Tier 1 CABAC UVM test"
	@echo "  vopt_random_cabac Run Tier 1 CABAC UVM test with -sv_seed random"
	@echo "  coverage_cabac    Run Tier 1 with coverage -> cabac.ucdb"
	@echo "  compile_axi       Compile Tier 2 59 RTL + SoC AMBA VIP/RAL/Env/Tests (+ vopt)"
	@echo "  vopt_run          Run Tier 2 test (test_name=hevc_full_uvm_test | hevc_ral_audit_test)"
	@echo "  vopt_random       Run Tier 2 test with -sv_seed random"
	@echo "  coverage          Run Tier 2 with coverage -> <test_name>.ucdb"
	@echo "  compile_all       Compile both Tier 1 and Tier 2 into work"
	@echo "  regression        Full Tier 1 + Tier 2A + Tier 2B coverage regression + vcover merge"
	@echo "  run / wave        Run unoptimized top or open GUI waveform"
	@echo "  vis_run           Run Visualizer flow (-qwavedb=+signal+class)"
	@echo "  clean             Remove simulation, UCDB, and build artifacts"
