
import rv32_ooo_pkg::*;
import mem_pkg::*;

module load_result_tb_wrapper (
    input logic clk,
    input logic rst_n,

    // Load queue
    input logic [XLEN-1:0] lq_out,
    input logic load_out_valid,
    output logic load_out_ready,
    input logic [ROB_TAG_W-1:0] load_out_rob_tag,
    input mem_size_e load_out_mem_size,
    input logic [1:0] load_out_byte_offset,
    input logic load_out_unsigned,
    input phys_reg_t load_out_writeback_pdst,
    input logic load_out_under_unresolved_branch,

    // Store queue
    input logic store_out_valid,
    output logic store_out_ready,
    input logic [ROB_TAG_W-1:0] store_out_rob_tag,
    input logic store_out_comp_under_branch,

    // ROB / writeback
    output logic result_valid,
    input logic result_ready,

    output logic [ROB_TAG_W-1:0] result_rob_tag,
    output logic result_writeback_valid,
    output phys_reg_t result_writeback_pdst,
    output logic [XLEN-1:0] result_value,
    output logic result_under_unresolved_branch
);

    execution_result_t result;

    load_result dut (
        .clk(clk),
        .rst_n(rst_n),

        .lq_out(lq_out),
        .load_out_valid(load_out_valid),
        .load_out_ready(load_out_ready),
        .load_out_rob_tag(rob_tag_t'(load_out_rob_tag)),
        .load_out_mem_size(load_out_mem_size),
        .load_out_byte_offset(load_out_byte_offset),
        .load_out_unsigned(load_out_unsigned),
        .load_out_writeback_pdst(load_out_writeback_pdst),
        .load_out_under_unresolved_branch(load_out_under_unresolved_branch),

        .store_out_valid(store_out_valid),
        .store_out_ready(store_out_ready),
        .store_out_rob_tag(rob_tag_t'(store_out_rob_tag)),
        .store_out_comp_under_branch(store_out_comp_under_branch),

        .result(result),
        .result_valid(result_valid),
        .result_ready(result_ready)
    );

    assign result_rob_tag = result.rob_tag;
    assign result_writeback_valid = result.writeback_valid;
    assign result_writeback_pdst = result.writeback_pdst;
    assign result_value = result.value;
    assign result_under_unresolved_branch =
        result.under_unresolved_branch;

endmodule
