SIM ?= verilator
TOPLEVEL_LANG = verilog

TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(TEST_DIR)/../../rtl)
PKG_DIR := $(abspath $(TEST_DIR)/../../../common)

VERILOG_SOURCES = \
    $(PKG_DIR)/rv32_ooo_pkg.sv \
    $(RTL_DIR)/mem_pkg.sv \
    $(RTL_DIR)/load_result.sv 

TOPLEVEL = load_result
COCOTB_TEST_MODULES = test_load_result


include $(shell cocotb-config --makefiles)/Makefile.sim
