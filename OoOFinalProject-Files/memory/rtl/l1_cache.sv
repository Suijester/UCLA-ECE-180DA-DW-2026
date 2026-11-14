import mem_pkg::*;
import rv32_ooo_pkg::*;

// lockup-free L1 dcache (reads out data & tags in parallel, then selects the data from matching tag)
module l1_cache (
    input logic clk,
    input logic rst_n,

    // capable of performing 1 load/store per cycle
    input logic req_valid,
    output logic req_ready,

    input logic req_is_store,
    input logic [XLEN-1:0] req_word_addr,
    input logic [3:0] req_bytes_accessed,
    input logic [XLEN-1:0] req_write_data,

    // tag memory requests
    input lq_idx_t req_ld_id,
    input st_idx_t req_st_id,
    
    // cache responses
    output logic resp_valid,
    output logic resp_hit,
    output logic resp_is_store,
    output logic [XLEN-1:0] resp_read_data,
    output lq_idx_t resp_ld_id,
    output st_idx_t resp_st_id,

    // send miss to MSHR
    output logic miss_valid,
    input logic miss_ready,
    output line_addr_t miss_line_addr,
    output logic [WORD_SEL_BITS-1:0] miss_critical_word,
    output logic miss_is_store,
    output lq_idx_t miss_ld_id,

    // fill from MSHR
    input logic fill_valid,
    output logic fill_ready,
    input line_pkd_t fill_line,

    // eviction to victim buffer
    output logic victim_valid,
    input logic victim_ready,
    output line_pkd_t victim_line 
);
    assign req_ready = (!fill_valid) && (miss_ready || tag_hit);

    // BRAM-mapped L1 cache (ways -> sets indexing)
    line_data_t l1_data [L1_WAYS][L1_SETS];

    // every cycle, read out the request's index for each way
    line_data_t l1_rd_out_data [L1_WAYS];

    // flop array (need to perform 4 tag compares in one cycle)
    logic [L1_TAG_BITS-1:0] l1_tags [L1_SETS][L1_WAYS];

    logic [L1_WAYS-1:0] l1_valid [L1_SETS];
    logic [L1_WAYS-1:0] l1_dirty [L1_SETS];
    logic [L1_WAYS-1:0] l1_reuse [L1_SETS]; // for interval prediction

    // generate tag, index bits from address
    logic [L1_TAG_BITS-1:0] req_tag;
    assign req_tag = req_word_addr[XLEN-1 -: L1_TAG_BITS];

    logic [L1_INDEX_BITS-1:0] req_index;
    assign req_index = req_word_addr[OFFSET_BITS +: L1_INDEX_BITS];

    logic [WORD_SEL_BITS-1:0] req_word_index;
    assign req_word_index = req_word_addr[2 +: WORD_SEL_BITS];

    // store hits, generate an enable for each byte in the block
    logic [BLOCK_SIZE-1:0] store_en;
    assign store_en = req_bytes_accessed << (4 * req_word_index);

    // check all the ways for matching tag (cache hit)
    logic tag_hit;
    l1_way_ptr_t tag_hit_way;

    always_comb begin : L1_TAG_COMPARISON
        tag_hit = 1'b0;
        tag_hit_way = '0;

        for (int i = 0; i < L1_WAYS; i++) begin
            if (l1_valid[req_index][i] && (l1_tags[req_index][i] == req_tag)) begin
                tag_hit = 1'b1;
                tag_hit_way = l1_way_ptr_t'(i);
            end
        end
    end

    // logic for next-cycle cache hit response
    l1_way_ptr_t hit_way_q;
    logic [WORD_SEL_BITS-1:0] word_index_q;

    assign resp_read_data = l1_rd_out_data[hit_way_q][word_index_q*XLEN +: XLEN];
    
    // find fill line's set index, tag
    logic [L1_INDEX_BITS-1:0] fill_index;
    assign fill_index = fill_line.line_addr[0 +: L1_INDEX_BITS];

    logic [L1_TAG_BITS-1:0] fill_tag;
    assign fill_tag = fill_line.line_addr[L1_INDEX_BITS +: L1_TAG_BITS];

    l1_way_ptr_t victim_way;

    // todo: change the logic later
    assign fill_ready = ~(&l1_valid[fill_index]);

    // todo: replace w/ tree plru logic
    always_comb begin
        victim_way = 0;
        for (int i = L1_WAYS - 1; i >= 0; i--) begin : find_victim_temp
            if (l1_valid[fill_index][i] == 0) begin
                victim_way = l1_way_ptr_t'(i);
            end
        end
    end

    // miss logic
    assign miss_valid = !fill_valid && !tag_hit && req_valid;
    assign miss_line_addr = req_word_addr >> OFFSET_BITS;
    assign miss_critical_word = req_word_index;
    assign miss_is_store = req_is_store;
    assign miss_ld_id = req_ld_id;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            resp_valid <= 1'b0;
            
            for (int i = 0; i < L1_SETS; i++) begin : clear_l1_valid
                l1_valid[i] <= '0;
            end

        end else begin
            resp_valid <= 1'b0;
            resp_hit <= 1'b0;

            // handle request
            if (req_valid && req_ready) begin
                resp_valid <= 1'b1;

                resp_hit <= tag_hit;
                resp_is_store <= req_is_store;

                resp_ld_id <= req_ld_id;
                resp_st_id <= req_st_id;

                hit_way_q <= tag_hit_way;
                word_index_q <= req_word_index;

                // load/store hit
                if (tag_hit) begin
                    // load hit, set reuse bit high
                    if (!req_is_store)
                        l1_reuse[req_index][tag_hit_way] <= 1'b1;
                    
                    // store request (edit l1 directly and mark data as dirty)
                    else begin
                        l1_dirty[req_index][tag_hit_way] <= 1'b1;
                        l1_reuse[req_index][tag_hit_way] <= 1'b1;
                    end
                end
            end

            // fill L1 cache
            if (fill_valid && fill_ready) begin
                l1_valid[fill_index][victim_way] <= 1'b1;
                l1_dirty[fill_index][victim_way] <= fill_line.dirty;
                l1_reuse[fill_index][victim_way] <= fill_line.reuse;
                l1_tags[fill_index][victim_way] <= fill_tag;
            end
        end
    end

    // bram handler (vendor blocks don't support reset)
    // explicitly generate each way (create L1_WAYS banks)
    generate 
        for (genvar i = 0; i < L1_WAYS; i++) begin : g_ways_data
            always_ff @(posedge clk) begin
                // fill L1 from MSHRS
                if (fill_valid && fill_ready && (victim_way == i)) begin
                    for (int b = 0; b < BLOCK_SIZE; b++) begin // process per-byte for bram inference
                        l1_data[i][fill_index][b*8 +: 8] <= fill_line.data[b*8 +: 8];
                    end
                end

                // on store hit, directly modify data in cache
                else if (req_valid && req_ready && req_is_store && tag_hit && (tag_hit_way == i)) begin
                    for (int b = 0; b < BLOCK_SIZE; b++) begin
                        if (store_en[b])
                            l1_data[i][req_index][b*8 +: 8] <= req_write_data[b[1:0]*8 +: 8];
                    end
                end

                l1_rd_out_data[i] <= l1_data[i][req_index];
            end
        end
    endgenerate

endmodule
