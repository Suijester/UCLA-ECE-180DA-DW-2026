import mem_pkg::*;

// lockup-free L2, serial tag and data-array access
module l2_cache (
    input logic clk,
    input logic rst_n,

    // MSHR snooping ports
    input logic mshr_req_valid,
    output logic mshr_req_ready,
    input mshr_id_t mshr_req_id,
    input line_addr_t mshr_req_line_addr,

    output logic mshr_resp_valid,
    output logic mshr_resp_hit,
    output line_pkd_t mshr_resp_line,
    output mshr_id_t mshr_resp_id,

    // fill ports from eviction buffer
    output logic l2_fill_ready,
    input logic l2_fill_valid,
    input line_pkd_t l2_fill_line,
    output logic l2_ins_done,

    // send victim to writeback buffer
    output logic l2_victim_valid,
    input logic l2_victim_ready,
    output line_pkd_t l2_victim_line
);

    // BRAM-mapped L2 cache (tags, lines, dirty, rrpv in BRAM)
    line_data_t l2_data [L2_WAYS][L2_SETS];
    logic [L2_TAG_BITS-1:0] l2_tags [L2_WAYS][L2_SETS];
    logic l2_dirty [L2_WAYS][L2_SETS];
    logic [1:0] l2_rrpv [L2_WAYS][L2_SETS];

    // L2 flop arrays
    logic [L2_WAYS-1:0] l2_valid [L2_SETS];

    // break up line address
    logic [L2_TAG_BITS-1:0] mshr_req_tag;
    logic [L2_INDEX_BITS-1:0] mshr_req_index;

    assign mshr_req_index = mshr_req_line_addr[0 +: L2_INDEX_BITS];
    assign mshr_req_tag = mshr_req_line_addr[L2_INDEX_BITS +: L2_TAG_BITS];

    // fill 

endmodule