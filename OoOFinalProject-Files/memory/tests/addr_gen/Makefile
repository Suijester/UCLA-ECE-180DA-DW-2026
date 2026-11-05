
SIM ?= verilator
TOPLEVEL_LANG = verilog

TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(TEST_DIR)/../../rtl)
PKG_DIR := $(abspath $(TEST_DIR)/../../../common)

VERILOG_SOURCES = \
    $(PKG_DIR)/rv32_ooo_pkg.sv \
    $(RTL_DIR)/address_gen.sv \
    $(TEST_DIR)addr_gen_tb_wrapper.sv

TOPLEVEL = addr_gen_tb_wrapper

MODULE = addr_gen_tb

include $(shell cocotb-config --makefiles)/Makefile.sim
