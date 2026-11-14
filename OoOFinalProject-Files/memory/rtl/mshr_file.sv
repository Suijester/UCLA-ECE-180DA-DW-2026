// mshrs: hold outstanding loads (enabling lockup free behavior) + coalesce loads w/ same line
module mshr_file (
    input logic clk,
    input logic rst_n,

    // load-miss from L1
    input logic miss_valid,
    output logic miss_ready,
    input line_addr_t miss_line_addr,
    input logic [WORD_SEL_BITS-1:0] miss_critical_word,
    input logic miss_is_store,
    input lq_idx_t miss_ld_id,

    // fill to L1 & broadcast line addr to LQ
    input logic fill_valid,
    output logic fill_ready,
    input line_pkd_t fill_line,

    output logic wake_valid,
    output line_addr_t wake_line_addr,

    // check eviction (L1 -> L2) buffer for hit

    // check L2 for hit

    // check wb (L2 -> MM) buffer

    // check main memory via arbiter interface

);


endmodule
