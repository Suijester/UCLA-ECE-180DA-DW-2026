SIM ?= verilator
TOPLEVEL_LANG = verilog

TEST_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
RTL_DIR := $(abspath $(TEST_DIR)/../../rtl)
PKG_DIR := $(abspath $(TEST_DIR)/../../../common)

VERILOG_SOURCES = \
    $(PKG_DIR)/rv32_ooo_pkg.sv \
    $(RTL_DIR)/mem_pkg.sv \
    $(RTL_DIR)/store_forward.sv \
    $(TEST_DIR)store_forward_tb_wrapper.sv

# store_forward.sv imports packages at file scope, like the rest of memory/rtl
EXTRA_ARGS += -Wno-IMPORTSTAR

TOPLEVEL = store_forward_tb_wrapper

MODULE = store_forward_tb

include $(shell cocotb-config --makefiles)/Makefile.sim