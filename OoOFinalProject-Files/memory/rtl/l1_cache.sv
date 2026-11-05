import mem_pkg::*;
import rv32_ooo_pkg::*;

// lockup-free L1 dcache
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
    output lq_idx_t miss_lq_id,

    // fill from MSHR
    input logic fill_valid,
    output logic fill_ready,
    input line_pkd_t fill_line,

    // eviction to victim buffer
    output logic victim_valid,
    input logic victim_ready,
    output line_pkd_t victim_line 
);

    // BRAM-mapped L1 cache (ways -> sets indexing)
    line_data_t l1_data [L1_WAYS][L1_SETS];

    // flop array (need to perform 4 tag compares in one cycle)
    logic [L1_TAG_BITS-1:0] l1_tags [L1_SETS][L1_WAYS];

    logic [L1_WAYS-1:0] l1_valid [L1_SETS];
    logic [L1_WAYS-1:0] l1_dirty [L1_SETS];
    logic [L1_WAYS-1:0] l1_reuse [L1_SETS];

    logic [L1_TAG_BITS-1:0] req_tag;
    assign req_tag = req_word_addr[XLEN-1 -: L1_TAG_BITS];

    logic [L1_INDEX_BITS-1:0] req_index;
    assign req_index = req_word_addr[OFFSET_BITS +: L1_INDEX_BITS];

    logic [WORD_SEL_BITS-1:0] req_word_index;
    assign req_word_index = req_word_addr[2 +: WORD_SEL_BITS];

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

    always_ff @(posedge clk) begin
        if (!rst_n) begin

        end else begin
            resp_valid <= 1'b0;
            resp_hit <= 1'b0;

            miss_valid <= 1'b0;

            // handle request
            if (req_valid && req_ready) begin
                resp_valid <= 1'b1;

                // load request
                if (!req_is_store) begin

                    // cache hit (resp_read_data bram access is handled in other block)
                    if (tag_hit) begin
                        resp_hit <= 1'b1;
                        resp_valid <= 1'b1;
                        resp_is_store <= 1'b0;

                        resp_ld_id <= req_ld_id;
                        resp_st_id <= req_st_id;
                    end 
                    
                    // todo: figure out miss handling
                    else if (miss_ready) begin

                    end
                end
                
                // store request
                else begin

                end
            end
        end
    end

    // bram handler (vendor blocks don't support reset)
    always_ff @(posedge clk) begin
        
    end

endmodule
