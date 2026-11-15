import mem_pkg::*;

// mshrs: hold outstanding loads (enabling lockup free behavior) + coalesce loads w/ same line
module mshr_file (
    input logic clk,
    input logic rst_n,

    // load-miss from L1
    input logic miss_valid,
    output logic miss_ready,
    input line_addr_t miss_line_addr,
    input logic [WORD_SEL_BITS-1:0] miss_critical_word, // tentatively unused, figure out arb first
    input logic miss_is_store,
    input lq_idx_t miss_ld_id,      // tentatively unused, figure out early restart later

    // fill to L1 & broadcast line addr to LQ
    output logic fill_valid,
    input logic fill_ready,
    output line_pkd_t fill_line,

    output logic wake_valid,
    output line_addr_t wake_line_addr,

    // check eviction (L1 -> L2) buffer for hit
    output logic eb_probe_valid,
    output line_addr_t eb_probe_line_addr,
    input logic eb_probe_retry,
    input logic eb_probe_hit,
    input line_pkd_t eb_probe_line,

    // check L2 for hit
    output logic l2_req_valid,
    input logic l2_req_ready,
    output mshr_id_t l2_req_mshr_id,
    output line_addr_t l2_line_addr,

    input logic l2_resp_valid,
    input logic l2_resp_hit,
    input line_pkd_t l2_resp_line,
    input mshr_id_t l2_resp_mshr_id,

    // check wb (L2 -> MM) buffer 
    // (tentatively, wb is basically eb and doesn't allow data in transit to get sent to mshr)
    output logic wb_probe_valid,
    output line_addr_t wb_probe_line_addr,
    input logic wb_probe_retry,
    input logic wb_probe_hit,
    input line_pkd_t wb_probe_line,

    // check main memory via arbiter interface
    output logic mem_req_valid,
    input logic mem_req_ready,
    output line_addr_t mem_req_line_addr,
    output mshr_id_t mem_req_mshr_id,

    input logic mem_resp_valid,
    input line_data_t mem_resp_data,
    input mshr_id_t mem_resp_mshr_id
);

    // mshr arrays (todo: if cwf, add new array later)
    logic [MSHR_COUNT-1:0] mshr_valid;
    line_addr_t [MSHR_COUNT-1:0] mshr_line_addr;
    mshr_state [MSHR_COUNT-1:0] mshr_access_states;
    line_pkd_t [MSHR_COUNT-1:0] mshr_line_buffer;

    // merge outstanding requests to same line address
    logic miss_coalesces;
    always_comb begin
        miss_coalesces = 1'b0;
        for (int i = 0; i < MSHR_COUNT; i++) begin : find_matching_mshr
            if (mshr_valid[i] && (mshr_line_addr[i] == miss_line_addr)) begin
                miss_coalesces = 1'b1;
            end
        end
    end

    // find first invalid mshr entry for allocation
    mshr_id_t alloc_mshr;
    always_comb begin
        alloc_mshr = '0;
        for (int i = MSHR_COUNT - 1; i >= 0; i--) begin : find_mshr_to_alloc
            if (!mshr_valid[i]) begin
                alloc_mshr = mshr_id_t'(i);
            end
        end
    end

    // generate request vectors from mshrs in the same state
    logic [MSHR_COUNT-1:0] req_eb, req_l2, req_wb, req_mm, req_fill;
    always_comb begin
        for (int i = 0; i < MSHR_COUNT; i++) begin : gen_req_vectors_mshr
            req_eb[i] = valid[i] && (mshr_access_states[i] == EB_SNOOP);
            req_l2[i] = valid[i] && (mshr_access_states[i] == L2_SNOOP);
            req_wb[i] = valid[i] && (mshr_access_states[i] == WB_SNOOP);
            req_mem[i] = valid[i] && (mshr_access_states[i] == MM_SNOOP);
            req_fill[i] = valid[i] && (mshr_access_states[i] == FILL_WAIT);
        end
    end

    assign miss_ready = !(&mshr_valid) || miss_coalesces;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mshr_valid <= '0;
        end else begin
            // allocate new mshr entry
            if (!miss_coalesces && miss_valid && miss_ready) begin
                mshr_valid[alloc_mshr] <= 1'b1;
                mshr_line_addr[alloc_mshr] <= miss_line_addr;
                mshr_access_states[alloc_mshr] <= EB_SNOOP;
            end


        end
    end

endmodule
