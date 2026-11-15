import mem_pkg::*;
import rv32_ooo_pkg::*;

// forward & merge (store-to-load forwarding)
//
// For each byte a load needs: take it from the YOUNGEST store that is OLDER
// than the load, has the same word address, and writes that byte. If no such
// store exists, take the byte from the cache (l1_cache resp_read_data, or the
// MSHR's early-restart word).
//
// Purely combinational, built as three parallel steps:
//   1. OLDER_MASK     : which SQ slots are older than the load
//   2. BYTE_MATCH     : which slots write each byte the load needs
//   3. YOUNGEST_SELECT: per byte, the matching slot closest to the load
//
// Age: a load records the SQ tail when it is allocated (ld_sq_tail). Slots
// from the SQ head up to that tail are older than the load. A slot's age is
// its distance from the head (0 = oldest).
//
// Store data from address_gen is copied into every byte lane, so byte b of a
// store is always sq_write_data[i][8*b +: 8].

module store_forward (
    //the load
    input logic [XLEN-1:0] ld_word_addr,              // address_gen.word_addr
    input logic [3:0] ld_bytes_accessed,              // address_gen.bytes_accessed
    input st_ptr_t ld_sq_tail,                        // SQ tail when the load was allocated

    // store queue view: store_queue sq_* outputs
    input st_ptr_t sq_head,
    input logic [SQ_SIZE-1:0] sq_valid,
    input logic [XLEN-1:0] sq_word_addr [SQ_SIZE],
    input logic [3:0] sq_bytes_accessed [SQ_SIZE],
    input logic [XLEN-1:0] sq_write_data [SQ_SIZE],

    // cache word (l1_cache resp_read_data, or the MSHR early-restart word)
    input logic [XLEN-1:0] cache_read_data,

    // result (to load_result for extract / extend)
    output logic [XLEN-1:0] fwd_data,
    output logic [3:0] fwd_bytes_from_store,          // which bytes came from a store
    output logic fwd_all_from_store                   // every needed byte forwarded: cache not needed
);

    localparam int SQ_IDX_BITS = $clog2(SQ_SIZE);

    st_idx_t head_idx;
    assign head_idx = sq_head[SQ_IDX_BITS-1:0];

    // how many stores are older than the load (0..SQ_SIZE)
    st_ptr_t ld_age;
    assign ld_age = ld_sq_tail - sq_head;

    // 1. which slots are older than the load
    logic [SQ_SIZE-1:0] older;

    //combinational logic to determine which store queue slots are older than the load
    always_comb begin : OLDER_MASK
        st_idx_t slot_age;
        for (int i = 0; i < SQ_SIZE; i++) begin
            slot_age = st_idx_t'(i) - head_idx;        // wraps mod SQ_SIZE
            older[i] = sq_valid[i] && (st_ptr_t'(slot_age) < ld_age);
        end
    end

    // 2. which older slots write each byte the load needs
    logic [3:0] byte_match [SQ_SIZE];

    //combinational logic to determine which older store queue slots write each byte the load needs
    always_comb begin : FIND_BYTE_MATCHES
        for (int i = 0; i < SQ_SIZE; i++) begin
            for (int b = 0; b < 4; b++) begin
                byte_match[i][b] = older[i]
                                && (sq_word_addr[i] == ld_word_addr)
                                && sq_bytes_accessed[i][b]
                                && ld_bytes_accessed[b];
            end
        end
    end

    // 3. per byte, pick the youngest matching slot
    //    walk ages oldest -> youngest; the last match wins (same pattern as the
    //    L1 tag compare), so the result is the youngest older store
    always_comb begin : YOUNGEST_SELECT
        st_idx_t slot;
        fwd_data = cache_read_data;
        fwd_bytes_from_store = '0;

        for (int a = 0; a < SQ_SIZE; a++) begin
            slot = head_idx + st_idx_t'(a);
            for (int b = 0; b < 4; b++) begin
                if (byte_match[slot][b]) begin
                    fwd_data[8*b +: 8] = sq_write_data[slot][8*b +: 8];
                    fwd_bytes_from_store[b] = 1'b1;
                end
            end
        end

        fwd_all_from_store = ((fwd_bytes_from_store & ld_bytes_accessed) == ld_bytes_accessed);
    end

    // NOTE (stage 3): in stages 1-2 every store's address is known at allocation,
    //   so every older store can be checked here. With dispatch-time allocation, a
    //   load must also wait (CONSERVATIVE) or be checked later (speculative modes)
    //   for older stores whose address is not yet known; that check belongs in
    //   load_queue.
    // NOTE: a store keeps forwarding until L1 confirms its write (drain hit),
    //   so a load never misses its bytes while the store is in flight to L1.

endmodule
