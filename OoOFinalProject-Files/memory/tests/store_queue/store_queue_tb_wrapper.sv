// flattens store_queue's struct and unpacked-array ports so cocotb can drive them
module store_queue_tb_wrapper
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
(
    input logic clk,
    input logic rst_n,

    // dispatch: only the two renamed_uop_t fields the store queue reads
    input logic disp_valid,
    input logic [ROB_TAG_W-1:0] disp_rob_tag,        // {generation, index}
    input logic disp_under_branch,
    output logic disp_ready,
    output logic [$clog2(SQ_SIZE):0] disp_st_ptr,

    input logic issue_valid,
    output logic issue_ready,
    input logic [ROB_TAG_W-1:0] issue_rob_tag,
    input logic [XLEN-1:0] issue_word_addr,
    input logic [3:0] issue_bytes_accessed,
    input logic [XLEN-1:0] issue_write_data,

    output logic comp_valid,
    input logic comp_ready,
    output logic [ROB_TAG_W-1:0] comp_rob_tag,
    output logic comp_under_branch,

    input logic [ROB_TAG_W-1:0] rob_head_tag,
    input logic br_resolve_valid,
    input logic br_mispredict,
    output logic [SQ_SIZE-1:0] sq_squash_mask,

    output logic [$clog2(SQ_SIZE):0] sq_head,
    output logic [$clog2(SQ_SIZE):0] sq_tail,
    output logic [SQ_SIZE-1:0] sq_valid,
    output logic [SQ_SIZE-1:0] sq_addr_valid,

    output logic drain_valid,
    input logic drain_ready,
    output logic [XLEN-1:0] drain_word_addr,
    output logic [3:0] drain_bytes_accessed,
    output logic [XLEN-1:0] drain_write_data,
    output logic [$clog2(SQ_SIZE)-1:0] drain_st_id,

    input logic drain_resp_valid,
    input logic drain_resp_hit,
    input logic [$clog2(SQ_SIZE)-1:0] drain_resp_st_id,

    input logic wake_valid,
    input logic [XLEN-OFFSET_BITS-1:0] wake_line_addr,

    output logic sq_empty,
    output logic sq_full
);

    renamed_uop_t disp_inst_s;
    rob_tag_t comp_tag_s;
    logic [XLEN-1:0] word_addr_arr [SQ_SIZE];
    logic [3:0] bytes_arr [SQ_SIZE];
    logic [XLEN-1:0] data_arr [SQ_SIZE];

    // build a renamed_uop_t with every other field zero
    always_comb begin
        disp_inst_s = '0;
        disp_inst_s.rob_tag = rob_tag_t'(disp_rob_tag);
        disp_inst_s.under_unresolved_branch = disp_under_branch;
    end

    assign comp_rob_tag = flatten_rob_tag(comp_tag_s);

    store_queue dut (
        .clk(clk), .rst_n(rst_n),
        .disp_valid(disp_valid), .disp_inst(disp_inst_s),
        .disp_ready(disp_ready), .disp_st_ptr(disp_st_ptr),
        .issue_valid(issue_valid), .issue_ready(issue_ready),
        .issue_rob_tag(rob_tag_t'(issue_rob_tag)),
        .issue_word_addr(issue_word_addr),
        .issue_bytes_accessed(issue_bytes_accessed),
        .issue_write_data(issue_write_data),
        .comp_valid(comp_valid), .comp_ready(comp_ready),
        .comp_rob_tag(comp_tag_s), .comp_under_branch(comp_under_branch),
        .rob_head_tag(rob_tag_t'(rob_head_tag)),
        .br_resolve_valid(br_resolve_valid), .br_mispredict(br_mispredict),
        .sq_squash_mask(sq_squash_mask),
        .sq_head(sq_head), .sq_tail(sq_tail),
        .sq_valid(sq_valid), .sq_addr_valid(sq_addr_valid),
        .sq_word_addr(word_addr_arr), .sq_bytes_accessed(bytes_arr), .sq_write_data(data_arr),
        .drain_valid(drain_valid), .drain_ready(drain_ready),
        .drain_word_addr(drain_word_addr), .drain_bytes_accessed(drain_bytes_accessed),
        .drain_write_data(drain_write_data), .drain_st_id(drain_st_id),
        .drain_resp_valid(drain_resp_valid), .drain_resp_hit(drain_resp_hit),
        .drain_resp_st_id(drain_resp_st_id),
        .wake_valid(wake_valid), .wake_line_addr(wake_line_addr),
        .sq_empty(sq_empty), .sq_full(sq_full)
    );

endmodule