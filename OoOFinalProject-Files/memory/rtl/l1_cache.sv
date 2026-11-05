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

    // instantiated L1 cache (indexed by ways -> sets for BRAM mapping)
    line_data_t l1_data [L1_WAYS][L1_SETS];

    // flop arrays of data
    logic [L1_WAYS-1:0] l1_valid [L1_SETS];
    logic [L1_WAYS-1:0] l1_dirty [L1_SETS];
    logic [L1_WAYS-1:0] l1_reuse [L1_SETS];

    // flop array (need to perform 4 tag compares in one cycle, so flops are easy)
    logic [L1_TAG_BITS-1:0] l1_tags [L1_SETS][L1_WAYS];

    logic [L1_TAG_BITS-1:0] req_tag;
    assign req_tag = req_word_addr[XLEN-1 -: L1_TAG_BITS];

    always_ff @(posedge clk) begin
        if (!rst_n) begin

        end else begin
            // handle request
            if (req_valid && req_ready) begin

                // load request
                if (!req_is_store) begin

                end
                
                // store request
                else begin

                end
            end
        end
    end

    // bram handler
    always_ff @(posedge clk) begin
        
    end

endmodule
