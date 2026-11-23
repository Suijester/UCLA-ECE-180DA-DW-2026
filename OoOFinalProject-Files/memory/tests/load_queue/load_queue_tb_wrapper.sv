import rv32_ooo_pkg::*;
import mem_pkg::*;

module load_queue_tb_wrapper (
    input logic clk, rst_n,

    // Dispatch
    input logic disp_valid,
    input logic [ROB_TAG_W-1:0] disp_rob_tag,
    input logic [1:0] disp_mem_size,
    input logic disp_unsigned,
    input phys_reg_t disp_pdst,
    input logic disp_under_unresolved_branch,
    output logic disp_ready,

    // Issue / AGU
    input logic [XLEN-1:0] word_addr,
    input logic [1:0] byte_offset,
    input logic [3:0] bytes_accessed,
    input logic misaligned_access,
    input logic [ROB_TAG_W-1:0] issue_rob_tag,
    input logic issue_valid,
    output logic issue_ready,

    // Retirement
    input logic retire_valid,
    input logic [ROB_TAG_W-1:0] retire_rob_tag,

    // Store queue
    input st_ptr_t sq_tail,

    // Store forwarding request
    output logic check_valid,
    output logic [XLEN-1:0] check_addr,
    output logic [3:0] check_byte_mask,
    output st_ptr_t check_sq_tail,

    // Store forwarding response
    input logic [XLEN-1:0] fwd_data,
    input logic [3:0] fwd_bytes_from_store,
    input logic fwd_all_from_store,
    input logic sq_stall,

    // Load completion
    output logic [XLEN-1:0] load_out,
    output logic load_out_valid,
    input logic load_out_ready,
    output logic [ROB_TAG_W-1:0] load_out_rob_tag,
    output mem_size_e load_out_mem_size,
    output logic [1:0] load_out_byte_offset,
    output logic load_out_unsigned,
    output logic load_out_under_unresolved_branch,
    output phys_reg_t load_out_writeback_pdst,

    // L1 request
    output logic l1_req_valid,
    output logic [XLEN-1:0] l1_req_addr,
    input logic l1_req_ready,
    output logic [3:0] l1_req_byte_mask,
    output lq_idx_t l1_req_ld_id,

    // L1 response
    input logic l1_resp_valid,
    input logic l1_resp_hit,
    input lq_idx_t l1_resp_ld_id,
    input logic [XLEN-1:0] l1_resp_data,

    // MSHR wakeup
    input logic wake_valid,
    input line_addr_t wake_line_addr,

    // New LQ status outputs
    output logic full,
    output logic empty,

    // Debug signals
    output lq_idx_t dbg_head, dbg_tail,
    output logic [$clog2(LQ_SIZE):0] dbg_count,
    output logic [LQ_SIZE-1:0] dbg_valid, dbg_addr_valid,
    output logic [LQ_SIZE-1:0] dbg_sq_checked, dbg_l1_waiting,
    output logic [LQ_SIZE-1:0] dbg_executed,
    output logic [LQ_SIZE-1:0] dbg_result_pending,
    output logic [XLEN-1:0] dbg_result_data
);

    renamed_uop_t disp_inst;

    always_comb begin
        disp_inst = '0;
        disp_inst.rob_tag = rob_tag_t'(disp_rob_tag);
        disp_inst.decoded.mem_size = mem_size_e'(disp_mem_size);
        disp_inst.decoded.load_unsigned = disp_unsigned;
        disp_inst.pdst = disp_pdst;
        disp_inst.under_unresolved_branch = disp_under_unresolved_branch;
    end

    load_queue dut (
        .clk(clk),
        .rst_n(rst_n),

        .disp_valid(disp_valid),
        .disp_inst(disp_inst),
        .disp_ready(disp_ready),

        .word_addr(word_addr),
        .byte_offset(byte_offset),
        .bytes_accessed(bytes_accessed),
        .misaligned_access(misaligned_access),
        .issue_rob_tag(rob_tag_t'(issue_rob_tag)),
        .issue_valid(issue_valid),
        .issue_ready(issue_ready),

        .retire_valid(retire_valid),
        .retire_rob_tag(rob_tag_t'(retire_rob_tag)),

        .sq_tail(sq_tail),

        .check_valid(check_valid),
        .check_addr(check_addr),
        .check_byte_mask(check_byte_mask),
        .check_sq_tail(check_sq_tail),
        .fwd_data(fwd_data),
        .fwd_bytes_from_store(fwd_bytes_from_store),
        .fwd_all_from_store(fwd_all_from_store),
        .sq_stall(sq_stall),

        .load_out(load_out),
        .load_out_valid(load_out_valid),
        .load_out_ready(load_out_ready),
        .load_out_rob_tag(load_out_rob_tag),
        .load_out_mem_size(load_out_mem_size),
        .load_out_byte_offset(load_out_byte_offset),
        .load_out_unsigned(load_out_unsigned),
        .load_out_under_unresolved_branch(load_out_under_unresolved_branch),
        .load_out_writeback_pdst(load_out_writeback_pdst),

        .l1_req_valid(l1_req_valid),
        .l1_req_addr(l1_req_addr),
        .l1_req_ready(l1_req_ready),
        .l1_req_byte_mask(l1_req_byte_mask),
        .l1_req_ld_id(l1_req_ld_id),

        .l1_resp_valid(l1_resp_valid),
        .l1_resp_hit(l1_resp_hit),
        .l1_resp_ld_id(l1_resp_ld_id),
        .l1_resp_data(l1_resp_data),

        .wake_valid(wake_valid),
        .wake_line_addr(wake_line_addr),

        .full(full),
        .empty(empty)
    );

    assign dbg_head = dut.head;
    assign dbg_tail = dut.tail;
    assign dbg_count = dut.count;

    for (genvar i = 0; i < LQ_SIZE; i++) begin : debug_entries
        assign dbg_valid[i] = dut.lq[i].valid;
        assign dbg_addr_valid[i] = dut.lq[i].addr_valid;
        assign dbg_sq_checked[i] = dut.lq[i].sq_checked;
        assign dbg_l1_waiting[i] = dut.lq[i].l1_waiting;
        assign dbg_executed[i] = dut.lq[i].executed;
        assign dbg_result_pending[i] = dut.lq[i].result_pending;
    end

    assign dbg_result_data = dut.lq[dut.selected_result_idx].result_data;

endmodule
