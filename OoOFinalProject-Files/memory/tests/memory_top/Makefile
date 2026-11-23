SIM ?= verilator
TOPLEVEL_LANG = verilog

TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(TEST_DIR)/../../rtl)
PKG_DIR := $(abspath $(TEST_DIR)/../../../common)

# Packages must appear before modules that import them.
VERILOG_SOURCES := \
    $(PKG_DIR)/rv32_ooo_pkg.sv \
    $(RTL_DIR)/mem_pkg.sv \
    $(PKG_DIR)/backend_memory_if.sv \
    $(PKG_DIR)/frontend_backend_if.sv \
    $(PKG_DIR)/data_memory_if.sv \
    $(filter-out $(RTL_DIR)/mem_pkg.sv,$(wildcard $(RTL_DIR)/*.sv)) \
    $(TEST_DIR)/memory_top_tb_wrapper.sv

TOPLEVEL = memory_top_tb_wrapper
COCOTB_TEST_MODULES = test_memory_top
EXTRA_ARGS += -Wno-fatal

include $(shell cocotb-config --makefiles)/Makefile.sim
