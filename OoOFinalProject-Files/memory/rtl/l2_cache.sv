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
    logic [L2_SETS-1:0][L2_WAYS-1:0] l2_valid;

    // maintain L2 cache state
    l2_state cache_state;

    assign mshr_req_ready = (cache_state == IDLE) && !(l2_fill_valid);
    assign l2_fill_ready = (cache_state == IDLE);

    // take in requests from either fill or mshrs on handshake
    mshr_id_t req_id_q;
    line_addr_t req_line_addr_q;
    line_pkd_t req_fill_line_q;

    logic [L2_TAG_BITS-1:0] req_tag_q;
    logic [L2_INDEX_BITS-1:0] req_index_q;

    assign req_index_q = req_line_addr_q[0 +: L2_INDEX_BITS];
    assign req_tag_q = req_line_addr_q[L2_INDEX_BITS +: L2_TAG_BITS];

    // break up line addrs for current same-cycle req
    line_addr_t selected_l2_req;
    logic [L2_TAG_BITS-1:0] l2_req_tag;
    logic [L2_INDEX_BITS-1:0] l2_req_index;

    assign selected_l2_req = (l2_fill_valid) ? l2_fill_line.line_addr : mshr_req_line_addr;
    assign l2_req_index = selected_l2_req[0 +: L2_INDEX_BITS];
    assign l2_req_tag = selected_l2_req[L2_INDEX_BITS +: L2_TAG_BITS];

    // matching cache tags, rrpv, dirty read out
    logic [L2_TAG_BITS-1:0] l2_read_tags [0:L2_WAYS-1];
    logic [1:0] l2_read_rrpv [0:L2_WAYS-1];
    logic l2_read_dirty [L2_WAYS];

    // todo: make actually serial
    line_data_t l2_read_data [0:L2_WAYS-1];

    // identify tag hit and way
    logic tag_hit;
    l2_way_ptr_t tag_hit_way;
    always_comb begin : L2_TAG_COMPARISON
        tag_hit = 1'b0;
        tag_hit_way = '0;

        for (int i = 0; i < L2_WAYS; i++) begin
            if (l2_valid[req_index_q][i] && (l2_read_tags[i] == req_tag_q)) begin
                tag_hit = 1'b1;
                tag_hit_way = l2_way_ptr_t'(i);
            end
        end
    end

    // response logic
    assign mshr_resp_line.dirty = l2_read_dirty[tag_hit_way];
    assign mshr_resp_line.line_addr = req_line_addr_q;
    assign mshr_resp_line.reuse = 1'b0;
    assign mshr_resp_line.data = l2_read_data[tag_hit_way];

    assign mshr_resp_valid = (cache_state == RESP);
    assign mshr_resp_hit = tag_hit;
    assign mshr_resp_id = req_id_q;

    // search for victim (instantiate rrip)
    l2_way_ptr_t victim_way;
    logic [1:0] new_rrpv [0:L2_WAYS-1];
    logic eviction_occurred;

    rrip rrip_handler (
        .l2_valid(l2_valid[req_index_q]),
        .rrpv(l2_read_rrpv),
        .fill_line_reuse(req_fill_line_q.reuse),

        .victim_way(victim_way),
        .new_rrpv(new_rrpv),
        .eviction_occurred(eviction_occurred)
    );

    // bram handler (vendor blocks don't support reset)
    generate 
        for (genvar i = 0; i < L2_WAYS; i++) begin : g_ways_data
            always_ff @(posedge clk) begin
                // read out data from BRAM
                l2_read_tags[i] <= l2_tags[i][(cache_state == IDLE) ? l2_req_index : req_index_q];
                l2_read_rrpv[i] <= l2_rrpv[i][(cache_state == IDLE) ? l2_req_index : req_index_q];
                l2_read_dirty[i] <= l2_dirty[i][(cache_state == IDLE) ? l2_req_index : req_index_q];
                l2_read_data[i] <= l2_data[i][req_index_q];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cache_state <= IDLE;
            l2_valid <= '0;

        end else begin
            case (cache_state)
                IDLE: begin
                    // prioritize fill > request
                    if (l2_fill_valid && l2_fill_ready) begin
                        req_fill_line_q <= l2_fill_line;
                        req_line_addr_q <= l2_fill_line.line_addr;
                        cache_state <= INS_SELECT;
                    end

                    if (mshr_req_valid && mshr_req_ready) begin
                        req_id_q <= mshr_req_id;
                        req_line_addr_q <= mshr_req_line_addr;
                        cache_state <= REQ_DATA;
                    end
                end

                REQ_DATA: cache_state <= RESP;

                RESP: begin
                    cache_state <= IDLE;
                    if (tag_hit) l2_valid[req_index_q][tag_hit_way] <= 1'b0;
                end

                INS_SELECT: begin

                end

                INS_EVICT: begin

                end

                INS_WRITE: begin

                end

                // should not occur
                default: cache_state <= IDLE;
            endcase
        end
    end

endmodule