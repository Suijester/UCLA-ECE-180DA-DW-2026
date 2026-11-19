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

    // check wb (L2 -> MEM) buffer 
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
    logic [MSHR_COUNT-1:0] req_eb, req_l2, req_wb, req_mem, req_fill;
    always_comb begin
        for (int i = 0; i < MSHR_COUNT; i++) begin : gen_req_vectors_mshr
            req_eb[i] = mshr_valid[i] && (mshr_access_states[i] == EB_SNOOP);
            req_l2[i] = mshr_valid[i] && (mshr_access_states[i] == L2_SNOOP);
            req_wb[i] = mshr_valid[i] && (mshr_access_states[i] == WB_SNOOP);
            req_mem[i] = mshr_valid[i] && (mshr_access_states[i] == MEM_SNOOP);
            req_fill[i] = mshr_valid[i] && (mshr_access_states[i] == FILL_WAIT);
        end
    end

    // bunch of rr arbiters to figure out which mshr gets to utilize the port
    mshr_id_t grant_index_eb, grant_index_l2, grant_index_wb, grant_index_mem, grant_index_fill;
    logic grant_valid_eb, grant_valid_l2, grant_valid_wb, grant_valid_mem, grant_valid_fill;

    // for eb and wb, we can always snoop freely, but wait for ready for everything else
    rr_arbiter #( .N(MSHR_COUNT) ) eb_arbiter ( .clk(clk), .rst_n(rst_n), 
    .reqs(req_eb), .grant_taken(1'b1), .grant_valid(grant_valid_eb), .grant_index(grant_index_eb));

    rr_arbiter #( .N(MSHR_COUNT) ) l2_arbiter ( .clk(clk), .rst_n(rst_n), 
    .reqs(req_l2), .grant_taken(l2_req_ready), .grant_valid(grant_valid_l2), .grant_index(grant_index_l2));

    rr_arbiter #( .N(MSHR_COUNT) ) wb_arbiter ( .clk(clk), .rst_n(rst_n), 
    .reqs(req_wb), .grant_taken(1'b1), .grant_valid(grant_valid_wb), .grant_index(grant_index_wb));

    rr_arbiter #( .N(MSHR_COUNT) ) mem_arbiter ( .clk(clk), .rst_n(rst_n), 
    .reqs(req_mem), .grant_taken(mem_req_ready), .grant_valid(grant_valid_mem), .grant_index(grant_index_mem));

    rr_arbiter #( .N(MSHR_COUNT) ) fill_arbiter ( .clk(clk), .rst_n(rst_n), 
    .reqs(req_fill), .grant_taken(fill_ready), .grant_valid(grant_valid_fill), .grant_index(grant_index_fill));

    assign miss_ready = !(&mshr_valid) || miss_coalesces;

    // snoop eviction buffer using arbiter results
    assign eb_probe_valid = grant_valid_eb;
    assign eb_probe_line_addr = mshr_line_addr[grant_index_eb];

    // snoop L2
    assign l2_req_valid = grant_valid_l2;
    assign l2_line_addr = mshr_line_addr[grant_index_l2];
    assign l2_req_mshr_id = grant_index_l2;

    // snoop wb
    assign wb_probe_valid = grant_valid_wb;
    assign wb_probe_line_addr = mshr_line_addr[grant_index_wb];

    // snoop mem
    assign mem_req_valid = grant_valid_mem;
    assign mem_req_line_addr = mshr_line_addr[grant_index_mem];
    assign mem_req_mshr_id = grant_index_mem;

    // fill port
    assign fill_valid = grant_valid_fill;
    assign fill_line = mshr_line_buffer[grant_index_fill];

    // wake up on fill
    assign wake_valid = (fill_valid && fill_ready);
    assign wake_line_addr = mshr_line_addr[grant_index_fill];

    // generate line_pkd_t from mem_resp_data
    line_pkd_t mem_pkd_line;
    assign mem_pkd_line.data = mem_resp_data;
    assign mem_pkd_line.line_addr = mshr_line_addr[mem_resp_mshr_id];
    assign mem_pkd_line.dirty = 1'b0;
    assign mem_pkd_line.reuse = 1'b0;

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

            // eb transition logic
            if (eb_probe_valid && eb_probe_hit) begin
                mshr_line_buffer[grant_index_eb] <= eb_probe_line;
                mshr_access_states[grant_index_eb] <= FILL_WAIT;
            end else if (eb_probe_valid && !eb_probe_retry) begin
                mshr_access_states[grant_index_eb] <= L2_SNOOP;
            end

            // l2 transition logic
            if (l2_req_valid && l2_req_ready)
                mshr_access_states[grant_index_l2] <= L2_WAIT;

            if (l2_resp_valid) begin
                mshr_access_states[l2_resp_mshr_id] <= (l2_resp_hit) ? FILL_WAIT : WB_SNOOP;
                mshr_line_buffer[l2_resp_mshr_id] <= l2_resp_line;
            end

            // wb transition logic
            if (wb_probe_valid && wb_probe_hit) begin
                mshr_line_buffer[grant_index_wb] <= wb_probe_line;
                mshr_access_states[grant_index_wb] <= FILL_WAIT;
            end else if (wb_probe_valid && !wb_probe_retry) begin
                mshr_access_states[grant_index_wb] <= MEM_SNOOP;
            end

            // main memory transition logic
            if (mem_req_valid && mem_req_ready)
                mshr_access_states[grant_index_mem] <= MEM_WAIT;

            if (mem_resp_valid) begin
                mshr_line_buffer[mem_resp_mshr_id] <= mem_pkd_line;
                mshr_access_states[mem_resp_mshr_id] <= FILL_WAIT;
            end

            // fill transition logic
            if (fill_valid && fill_ready) begin
                mshr_valid[grant_index_fill] <= 1'b0;
            end
        end
    end

endmodule
