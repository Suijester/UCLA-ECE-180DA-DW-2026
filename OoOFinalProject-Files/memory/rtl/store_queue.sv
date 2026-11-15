import mem_pkg::*;
import rv32_ooo_pkg::*;

// store queue (retired entries at the head are the store buffer)
//
// build stages 1-2:
//   - entries are allocated at ISSUE; address + data arrive in the same cycle
//     from address_gen, so an entry is resolved as soon as it is allocated
//   - the backend issues memory ops in program order, so allocation order
//     equals program order (age = position from the head, NOT rob_tag)
//
// lifecycle of an entry:
//   allocate (tail) -> complete to ROB -> retire (ROB head moved past it)
//   -> drain to L1 from the head, in order -> free on an L1 hit
//   a drain that misses L1 waits for the MSHR to fill the line, then retries
//   a mispredict frees every unretired entry with under_branch set
module store_queue (
    input logic clk,
    input logic rst_n,

    // allocate (from memory_top, fed by address_gen)
    input logic alloc_valid,
    output logic alloc_ready,                         // low when full
    input rob_tag_t alloc_rob_tag,
    input logic alloc_under_branch,                   // issue_uop.under_unresolved_branch
    input logic [XLEN-1:0] alloc_word_addr,           // address_gen.word_addr
    input logic [3:0] alloc_bytes_accessed,           // address_gen.bytes_accessed
    input logic [XLEN-1:0] alloc_write_data,          // address_gen.store_data (copied into every lane)
    output st_ptr_t alloc_st_ptr,                     // slot this store got (store_sets disp_st_ptr)

    // completion to the ROB (load_result builds execution_result_t, writeback_valid = 0)
    output logic comp_valid,
    output rob_tag_t comp_rob_tag,
    output logic comp_under_branch,

    // retirement and branch recovery
    input rob_tag_t rob_head_tag,                     // be.rob_head_tag
    input logic br_resolve_valid,
    input logic br_mispredict,
    output logic [SQ_SIZE-1:0] sq_squash_mask,        // slots freed by this mispredict (store_sets)

    // forwarding view (to store_forward)
    output st_ptr_t sq_head,
    output st_ptr_t sq_tail,                          // a new load records this: its older stores are head..tail-1
    output logic [SQ_SIZE-1:0] sq_valid,
    output logic [XLEN-1:0] sq_word_addr [SQ_SIZE],
    output logic [3:0] sq_bytes_accessed [SQ_SIZE],
    output logic [XLEN-1:0] sq_write_data [SQ_SIZE],

    // drain request to L1 (memory_top drives l1_cache req_* with req_is_store = 1)
    output logic drain_valid,
    input logic drain_ready,                          // l1_cache req_ready, and the L1 port arbiter picked us
    output logic [XLEN-1:0] drain_word_addr,          // -> req_word_addr
    output logic [3:0] drain_bytes_accessed,          // -> req_bytes_accessed
    output logic [XLEN-1:0] drain_write_data,         // -> req_write_data
    output st_idx_t drain_st_id,                      // -> req_st_id

    // drain response from L1 (memory_top passes l1_cache resp_* when resp_is_store = 1)
    input logic drain_resp_valid,
    input logic drain_resp_hit,
    input st_idx_t drain_resp_st_id,

    // line filled by an MSHR (mshr_file wake_*): a store that missed can retry
    input logic wake_valid,
    input line_addr_t wake_line_addr,

    // status
    output logic sq_empty,                            // feeds be.busy: retired stores not yet in L1
    output logic sq_full
);

    localparam int SQ_IDX_BITS = $clog2(SQ_SIZE);

    // per-field storage (flops: valid/retired/under_branch change every cycle
    // and are read in parallel, like l1_valid in l1_cache)
    logic [SQ_SIZE-1:0] sq_retired;
    logic [SQ_SIZE-1:0] sq_under_branch;
    rob_tag_t sq_rob_tag [SQ_SIZE];

    // pointers: one extra wrap bit above the index
    //   empty: head == tail      full: same index, different wrap bit
    st_ptr_t head, tail;
    st_idx_t head_idx, tail_idx;

    assign head_idx = head[SQ_IDX_BITS-1:0];
    assign tail_idx = tail[SQ_IDX_BITS-1:0];

    assign sq_empty = (head == tail);
    assign sq_full = (head_idx == tail_idx) && (head[SQ_IDX_BITS] != tail[SQ_IDX_BITS]);

    assign sq_head = head;
    assign sq_tail = tail;

    // ---------------------------------------------------------------------
    // branch resolve (the core allows one unresolved branch -> one bit per entry)
    // ---------------------------------------------------------------------
    logic br_squash, br_correct;
    assign br_squash = br_resolve_valid && br_mispredict;
    assign br_correct = br_resolve_valid && !br_mispredict;

    // squashed: unretired entries younger than the branch
    always_comb begin : SQ_FIND_SQUASHED
        for (int i = 0; i < SQ_SIZE; i++)
            sq_squash_mask[i] = br_squash && sq_valid[i] && sq_under_branch[i] && !sq_retired[i];
    end

    // squashed entries are always the youngest block right before the tail,
    // so the new tail = head + number of surviving entries
    st_ptr_t survivors;
    assign survivors = st_ptr_t'($countones(sq_valid & ~sq_squash_mask));

    // ---------------------------------------------------------------------
    // allocate (a store on the mispredicted path arriving with the squash is dropped)
    // ---------------------------------------------------------------------
    logic alloc_fire, alloc_keep;
    st_ptr_t alloc_ptr;
    st_idx_t alloc_idx;

    assign alloc_ready = !sq_full;
    assign alloc_fire = alloc_valid && alloc_ready;
    assign alloc_keep = alloc_fire && !(br_squash && alloc_under_branch);
    assign alloc_ptr = br_squash ? (head + survivors) : tail;
    assign alloc_idx = alloc_ptr[SQ_IDX_BITS-1:0];
    assign alloc_st_ptr = alloc_ptr;

    // completion: one pulse when the store is captured (none for a dropped store)
    assign comp_valid = alloc_keep;
    assign comp_rob_tag = alloc_rob_tag;
    assign comp_under_branch = alloc_under_branch && !br_correct;

    // ---------------------------------------------------------------------
    // retirement: a store has retired once the ROB head has moved past it
    //   rob_tag_distance(head, store) = 0          store is at the head, not retired
    //                                 1..16         head is past it -> retired
    //                                 larger        store is still ahead of the head
    //   checked every cycle and latched, so a later tag wrap can't undo it
    // ---------------------------------------------------------------------
    logic [SQ_SIZE-1:0] retire_now;
    rob_tag_flat_t head_dist [SQ_SIZE];

    always_comb begin : SQ_RETIRE_DETECT
        for (int i = 0; i < SQ_SIZE; i++) begin
            head_dist[i] = rob_tag_distance(rob_head_tag, sq_rob_tag[i]);
            retire_now[i] = sq_valid[i] && !sq_retired[i]
                         && (head_dist[i] != '0)
                         && (head_dist[i] <= rob_tag_flat_t'(ROB_ENTRY_COUNT));
        end
    end

    // ---------------------------------------------------------------------
    // drain: only the HEAD entry, only once retired, one request at a time
    //   drain_pending : request accepted by L1, waiting for its response
    //   wait_wake     : L1 missed (it sent the line to an MSHR, write-allocate);
    //                   wait for that line to be filled, then send the store again
    // ---------------------------------------------------------------------
    logic drain_pending, wait_wake, wake_seen;
    logic drain_fire, drain_hit, drain_miss, head_wake;

    line_addr_t head_line;
    assign head_line = sq_word_addr[head_idx][XLEN-1:OFFSET_BITS];

    assign drain_valid = sq_valid[head_idx] && sq_retired[head_idx] && !drain_pending && !wait_wake;
    assign drain_word_addr = sq_word_addr[head_idx];
    assign drain_bytes_accessed = sq_bytes_accessed[head_idx];
    assign drain_write_data = sq_write_data[head_idx];
    assign drain_st_id = head_idx;

    assign drain_fire = drain_valid && drain_ready;
    assign drain_hit = drain_pending && drain_resp_valid && drain_resp_hit && (drain_resp_st_id == head_idx);
    assign drain_miss = drain_pending && drain_resp_valid && !drain_resp_hit && (drain_resp_st_id == head_idx);
    assign head_wake = wake_valid && (wake_line_addr == head_line);

    // ---------------------------------------------------------------------
    // control state
    // ---------------------------------------------------------------------
    always_ff @(posedge clk) begin : SQ_CONTROL
        if (!rst_n) begin
            head <= '0;
            tail <= '0;
            sq_valid <= '0;
            sq_retired <= '0;
            sq_under_branch <= '0;
            drain_pending <= 1'b0;
            wait_wake <= 1'b0;
            wake_seen <= 1'b0;
        end else begin
            // 1. mark newly retired entries
            for (int i = 0; i < SQ_SIZE; i++) begin
                if (retire_now[i]) sq_retired[i] <= 1'b1;
            end

            // 2. branch resolve
            if (br_squash) begin
                sq_valid <= sq_valid & ~sq_squash_mask;
                tail <= head + survivors;
            end
            if (br_correct) begin
                sq_under_branch <= '0;
            end

            // 3. allocate (after the squash so it lands at the rolled-back tail)
            if (alloc_keep) begin
                sq_valid[alloc_idx] <= 1'b1;
                sq_retired[alloc_idx] <= 1'b0;
                sq_under_branch[alloc_idx] <= alloc_under_branch && !br_correct;
                tail <= alloc_ptr + 1'b1;
            end

            // 4. drain handshake with L1 (the head entry is retired, so a squash never touches it)
                        // 4. drain handshake with L1 (the head entry is retired, so a squash never touches it)
            if (drain_fire) drain_pending <= 1'b1;

            if (drain_hit) begin
                sq_valid[head_idx] <= 1'b0;
                head <= head + 1'b1;
                drain_pending <= 1'b0;
            end
            
            // listen for the head line's wake from the moment the request is sent:
            // remember a wake seen in the send cycle or while waiting for the response
            if (drain_fire) begin
                wake_seen <= head_wake;
            end else if (drain_pending && head_wake) begin
                wake_seen <= 1'b1;
            end

             // a miss waits for the fill, unless its wake already came (earlier in
            // flight, or in this same cycle): then retry straight away
            if (drain_miss) begin
                drain_pending <= 1'b0;
                wait_wake <= !(wake_seen || head_wake);
                wake_seen <= 1'b0;
            end else if (wait_wake && head_wake) begin
                wait_wake <= 1'b0;
            end

            if (drain_hit) begin
                wake_seen <= 1'b0;
            end
        end
    end

    // payload storage (no reset needed: only read when sq_valid is set)
    always_ff @(posedge clk) begin : SQ_PAYLOAD
        if (alloc_keep) begin
            sq_rob_tag[alloc_idx] <= alloc_rob_tag;
            sq_word_addr[alloc_idx] <= alloc_word_addr;
            sq_bytes_accessed[alloc_idx] <= alloc_bytes_accessed;
            sq_write_data[alloc_idx] <= alloc_write_data;
        end
    end

endmodule
