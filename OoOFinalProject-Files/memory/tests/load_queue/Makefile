SIM ?= verilator
TOPLEVEL_LANG = verilog

TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(TEST_DIR)/../../rtl)
PKG_DIR := $(abspath $(TEST_DIR)/../../../common)

VERILOG_SOURCES = \
    $(PKG_DIR)/rv32_ooo_pkg.sv \
    $(RTL_DIR)/mem_pkg.sv \
    $(RTL_DIR)/load_queue.sv \
    $(TEST_DIR)/load_queue_tb_wrapper.sv

TOPLEVEL = load_queue_tb_wrapper
COCOTB_TEST_MODULES = test_load_queue

# Run: make (from memory/tests/load_queue/)
# Optional: make SIM=icarus
include $(shell cocotb-config --makefiles)/Makefile.sim
