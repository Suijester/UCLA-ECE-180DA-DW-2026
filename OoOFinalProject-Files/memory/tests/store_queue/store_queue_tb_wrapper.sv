// flattens store_queue's struct and unpacked-array ports so cocotb can drive them
module store_queue_tb_wrapper
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
(
    input logic clk,
    input logic rst_n,

    input logic alloc_valid,
    output logic alloc_ready,
    input logic [ROB_TAG_W-1:0] alloc_rob_tag,       // {generation, index}
    input logic alloc_under_branch,
    input logic [XLEN-1:0] alloc_word_addr,
    input logic [3:0] alloc_bytes_accessed,
    input logic [XLEN-1:0] alloc_write_data,
    output logic [$clog2(SQ_SIZE):0] alloc_st_ptr,

    output logic comp_valid,
    output logic [ROB_TAG_W-1:0] comp_rob_tag,
    output logic comp_under_branch,

    input logic [ROB_TAG_W-1:0] rob_head_tag,
    input logic br_resolve_valid,
    input logic br_mispredict,
    output logic [SQ_SIZE-1:0] sq_squash_mask,

    output logic [$clog2(SQ_SIZE):0] sq_head,
    output logic [$clog2(SQ_SIZE):0] sq_tail,
    output logic [SQ_SIZE-1:0] sq_valid,

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

    rob_tag_t comp_tag_s;
    logic [XLEN-1:0] word_addr_arr [SQ_SIZE];
    logic [3:0] bytes_arr [SQ_SIZE];
    logic [XLEN-1:0] data_arr [SQ_SIZE];

    assign comp_rob_tag = flatten_rob_tag(comp_tag_s);

    store_queue dut (
        .clk(clk), .rst_n(rst_n),
        .alloc_valid(alloc_valid), .alloc_ready(alloc_ready),
        .alloc_rob_tag(rob_tag_t'(alloc_rob_tag)),
        .alloc_under_branch(alloc_under_branch),
        .alloc_word_addr(alloc_word_addr),
        .alloc_bytes_accessed(alloc_bytes_accessed),
        .alloc_write_data(alloc_write_data),
        .alloc_st_ptr(alloc_st_ptr),
        .comp_valid(comp_valid), .comp_rob_tag(comp_tag_s), .comp_under_branch(comp_under_branch),
        .rob_head_tag(rob_tag_t'(rob_head_tag)),
        .br_resolve_valid(br_resolve_valid), .br_mispredict(br_mispredict),
        .sq_squash_mask(sq_squash_mask),
        .sq_head(sq_head), .sq_tail(sq_tail), .sq_valid(sq_valid),
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