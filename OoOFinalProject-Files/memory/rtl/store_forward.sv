// Forward & merge
//STATUS: will start [Noosha]

/*WHAT IT DOES
    - A load might read an address that an OLDER store wrote but has not yet
    put into L1 (it is still in the store queue). 
    - This block builds thecorrect 4-byte word for the load, one byte at a time.
*/

/*TALKS TO
    - in  <- load_queue   : the load's word_addr, bytes_accessed, its age
    - in  <- store_queue  : every entry's word_addr, byte_en, data, valid/age
    - in  <- l1_cache     : the word read from L1 (on a hit)
    - in  <- mshr_file    : the word that just arrived from L2/RAM (on a miss)
    - out -> load_result  : the merged 32-bit word
*/ 

/* HOW IT WORKS (per byte, 4 times in parallel)
    - For byte i of the word:
        look at stores that are OLDER than the load, same word_addr,
        and whose byte_en[i] is 1  ->  take the YOUNGEST of those.
        If no such store, take byte i from L1 (or the MSHR).
*/

module store_forward
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
(
    // ----- The load ----------------------------------------------------------
    input  logic [XLEN-1:0] ld_word_addr_i,        // address_gen.word_addr
    input  logic [3:0]      ld_byte_en_i,          // address_gen.bytes_accessed
    input  st_ptr_t         ld_sq_tail_i,          // SQ tail when the load was allocated
 
    // ----- Store queue view (store_queue fwd_* outputs) ----------------------
    input  st_ptr_t                          sq_head_i,
    input  logic     [SQ_SIZE-1:0]           sq_valid_i,
    input  logic     [SQ_SIZE-1:0][XLEN-1:0] sq_word_addr_i,
    input  logic     [SQ_SIZE-1:0][3:0]      sq_byte_en_i,
    input  logic     [SQ_SIZE-1:0][XLEN-1:0] sq_data_i,
 
    // ----- Cache word (L1 hit, or the MSHR's early-restart word) ------------
    input  logic [XLEN-1:0] cache_data_i,
 
    // ----- Result ------------------------------------------------------------
    output logic [XLEN-1:0] merged_data_o,         // to load_result for extract / extend
    output logic [3:0]      byte_from_store_o,     // which bytes came from a store
    output logic            all_from_store_o       // every needed byte forwarded: no cache read needed
);
 
    always_comb begin
        st_ptr_t ptr;
        st_idx_t idx;
        logic    in_range;
 
        // Start with the cache's bytes, then let older stores overwrite them.
        merged_data_o     = cache_data_i;
        byte_from_store_o = '0;
        in_range          = 1'b1;
 
        // Visit SQ entries oldest -> youngest, stopping at the load's tail.
        for (int i = 0; i < SQ_SIZE; i++) begin
            ptr = sq_head_i + st_ptr_t'(i);
            idx = ptr[$clog2(SQ_SIZE)-1:0];
            if (ptr == ld_sq_tail_i) in_range = 1'b0;   // reached stores younger than the load
 
            if (in_range && sq_valid_i[idx] && (sq_word_addr_i[idx] == ld_word_addr_i)) begin
                for (int b = 0; b < 4; b++) begin
                    if (ld_byte_en_i[b] && sq_byte_en_i[idx][b]) begin
                        merged_data_o[8*b +: 8] = sq_data_i[idx][8*b +: 8];
                        byte_from_store_o[b]    = 1'b1;
                    end
                end
            end
        end
 
        all_from_store_o = ((byte_from_store_o & ld_byte_en_i) == ld_byte_en_i);
    end
 
    // -------------------------------------------------------------------------
    // TODO (CONSERVATIVE mode): the load may only use this result once every
    // older store has a known address. In stages 1-2 addresses arrive with
    // allocation, so this is always true; in stage 3 add an
    // "older_store_unknown" output here or in load_queue.
    //
    // TODO (timing): this loop is a chain of 8 comparisons per byte. Fine for
    // 8 entries; revisit if it becomes the critical path.
    // =========================================================================
endmodule
