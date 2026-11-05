// Store queue (retired entries at the head are the store buffer)
//STATUS: will start [Noosha]

/* WHAT IT DOES
   - A waiting room for stores.
   - A store may not change memory until the ROB
   retires it (it might be on a wrong branch path and get thrown away), so
   every store sits here from issue until it is safely written into L1.
   - The retired entries at the head of the queue act as the "store buffer".
*/

/* TALKS TO
   - in  <- address_gen     : word_addr, bytes_accessed (byte enables),
                            store_data (already copied into every byte lane)
   - in  <- backend          : rob_tag of the store; under_unresolved_branch bit
   - in  <- backend_memory_if: rob_head_tag (tells us when a store has retired)
   - in  <- branch resolve   : mispredict -> squash wrong-path stores
   - out -> load_result      : "this store is done" completion to the ROB
                            (writeback_valid = 0, stores have no register result)
   - out -> store_forward    : every entry's addr / byte_en / data, so loads can
                            take bytes from older stores
   - out -> l1_cache         : the oldest retired store, to be written (drained)
   - out -> memory_top       : full / free count, so issue can stall
*/

/* STATE PER ENTRY (see mem_pkg: SQ_SIZE = 8, st_idx_t, st_ptr_t)
   valid, rob_tag, word_addr, byte_en[3:0], data[31:0],
   resolved (addr+data captured), retired, under_branch,
   later (stage 3): set_id for store sets
/*

+// LIFECYCLE OF ONE ENTRY
   FREE -> ALLOCATED (tail++) -> RESOLVED (addr/data written, completion sent)
        -> RETIRED (ROB head moved past it) -> DRAINING (writing L1)
        -> FREE (head++ once L1 accepts the write)
*/

module store_queue
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,
 
    // ----- Allocate (from memory_top, fed by address_gen) -----------------
    input  logic            alloc_valid_i,
    output logic            alloc_ready_o,         // low when full
    input  rob_tag_t        alloc_rob_tag_i,
    input  logic            alloc_under_branch_i,  // issue_uop.under_unresolved_branch
    input  logic [XLEN-1:0] alloc_word_addr_i,     // address_gen.word_addr
    input  logic [3:0]      alloc_byte_en_i,       // address_gen.bytes_accessed
    input  logic [XLEN-1:0] alloc_data_i,          // address_gen.store_data (copied into every lane)
 
    // ----- Completion to the ROB (through load_result) --------------------
    // A store has no register result, so it completes as soon as it is
    // captured. load_result turns this into an execution_result_t with
    // writeback_valid = 0 and queues it if the backend is busy.
    output logic            complete_valid_o,
    output rob_tag_t        complete_rob_tag_o,
    output logic            complete_under_branch_o,
 
    // ----- Retirement and recovery ------------------------------------------
    input  rob_tag_t        rob_head_tag_i,        // be.rob_head_tag
    input  logic            branch_resolve_valid_i,
    input  logic            branch_mispredict_i,
 
    // ----- Forwarding view (to store_forward) ------------------------------
    output logic     [SQ_SIZE-1:0]           fwd_valid_o,
    output logic     [SQ_SIZE-1:0][XLEN-1:0] fwd_word_addr_o,
    output logic     [SQ_SIZE-1:0][3:0]      fwd_byte_en_o,
    output logic     [SQ_SIZE-1:0][XLEN-1:0] fwd_data_o,
    output st_ptr_t                          head_ptr_o,
    output st_ptr_t                          tail_ptr_o,    // a new load records this: older stores are head..tail-1
 
    // ----- Drain to L1 (oldest retired store) ------------------------------
    output logic            drain_valid_o,
    input  logic            drain_ready_i,         // L1 accepted the write this cycle
    output logic [XLEN-1:0] drain_word_addr_o,
    output logic [3:0]      drain_byte_en_o,
    output logic [XLEN-1:0] drain_data_o,
 
    // ----- Status ------------------------------------------------------------
    output logic            empty_o,               // feeds be.busy: retired stores not yet in L1
    output logic            full_o
);
 
    // -------------------------------------------------------------------------
    // Entry storage
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic            valid;
        rob_tag_t        rob_tag;
        logic [XLEN-1:0] word_addr;
        logic [3:0]      byte_en;
        logic [XLEN-1:0] data;
        logic            retired;       // ROB has retired it: allowed to write L1
        logic            under_branch;  // younger than the one unresolved branch
    } sq_entry_t;
 
    sq_entry_t entries_q [SQ_SIZE];
 
    // -------------------------------------------------------------------------
    // Head / tail pointers
    // st_ptr_t has one extra wrap bit above the index bits.
    //   empty: head == tail (same index, same wrap bit)
    //   full : same index, different wrap bit
    // -------------------------------------------------------------------------
    st_ptr_t head_q, tail_q;
    st_idx_t head_idx, tail_idx;
 
    assign head_idx = head_q[$clog2(SQ_SIZE)-1:0];
    assign tail_idx = tail_q[$clog2(SQ_SIZE)-1:0];
 
    assign empty_o = (head_q == tail_q);
    assign full_o  = (head_idx == tail_idx) &&
                     (head_q[$clog2(SQ_SIZE)] != tail_q[$clog2(SQ_SIZE)]);
 
    assign alloc_ready_o = !full_o;
 
    logic alloc_fire, drain_fire;
    assign alloc_fire = alloc_valid_i && alloc_ready_o;
    assign drain_fire = drain_valid_o && drain_ready_i;
 
    // -------------------------------------------------------------------------
    // Completion: one pulse in the cycle the store is captured
    // -------------------------------------------------------------------------
    assign complete_valid_o        = alloc_fire;
    assign complete_rob_tag_o      = alloc_rob_tag_i;
    assign complete_under_branch_o = alloc_under_branch_i;
 
    // -------------------------------------------------------------------------
    // Drain: only the HEAD entry, and only once it has retired
    // -------------------------------------------------------------------------
    assign drain_valid_o     = entries_q[head_idx].valid && entries_q[head_idx].retired;
    assign drain_word_addr_o = entries_q[head_idx].word_addr;
    assign drain_byte_en_o   = entries_q[head_idx].byte_en;
    assign drain_data_o      = entries_q[head_idx].data;
 
    // -------------------------------------------------------------------------
    // Forwarding view
    // -------------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < SQ_SIZE; i++) begin
            fwd_valid_o[i]     = entries_q[i].valid;
            fwd_word_addr_o[i] = entries_q[i].word_addr;
            fwd_byte_en_o[i]   = entries_q[i].byte_en;
            fwd_data_o[i]      = entries_q[i].data;
        end
    end
    assign head_ptr_o = head_q;
    assign tail_ptr_o = tail_q;
 
    // -------------------------------------------------------------------------
    // TODO: retirement detection
    // A store has retired once the ROB head has moved past it.
    // Idea: rob_tag_distance(rob_head_tag_i, entry.rob_tag) is how far the head
    // is beyond the store. 0 = the store is AT the head (not retired yet).
    // 1 .. ROB_ENTRY_COUNT = head has moved past it -> retired.
    // Larger values = the store is still ahead of the head.
    // Check every cycle and latch the bit, so a later wrap can't undo it.
    // Alternative: retire_valid / retire_tag from frontend_backend_if (needs
    // a new port on memory_top).
    // -------------------------------------------------------------------------
    logic [SQ_SIZE-1:0] retire_now;
    always_comb begin
        retire_now = '0;
        // TODO: for each valid, not-yet-retired entry, set retire_now[i]
    end
 
    // -------------------------------------------------------------------------
    // TODO: branch squash / resolve
    // The core allows one unresolved branch, so one bit per entry is enough.
    //   mispredict : clear valid on every entry with under_branch && !retired,
    //                then move tail_q back to just after the youngest survivor.
    //                (Those entries are always the youngest ones, so they sit
    //                in one block right before the tail.)
    //   correct    : clear under_branch on every entry.
    // Retired entries are never squashed.
    // -------------------------------------------------------------------------
    logic squash, resolve_ok;
    assign squash     = branch_resolve_valid_i &&  branch_mispredict_i;
    assign resolve_ok = branch_resolve_valid_i && !branch_mispredict_i;
 
    // -------------------------------------------------------------------------
    // State update
    // -------------------------------------------------------------------------
    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            head_q <= '0;
            tail_q <= '0;
            for (int i = 0; i < SQ_SIZE; i++) entries_q[i].valid <= 1'b0;
        end else begin
            // Allocate at the tail
            if (alloc_fire) begin
                entries_q[tail_idx] <= '{
                    valid:        1'b1,
                    rob_tag:      alloc_rob_tag_i,
                    word_addr:    alloc_word_addr_i,
                    byte_en:      alloc_byte_en_i,
                    data:         alloc_data_i,
                    retired:      1'b0,
                    under_branch: alloc_under_branch_i
                };
                tail_q <= tail_q + 1'b1;
            end
 
            // Free the head once L1 accepts its write
            if (drain_fire) begin
                entries_q[head_idx].valid <= 1'b0;
                head_q <= head_q + 1'b1;
            end
 
            // Mark newly retired entries
            for (int i = 0; i < SQ_SIZE; i++)
                if (retire_now[i]) entries_q[i].retired <= 1'b1;
 
            // TODO: squash (and tail rollback) / resolve_ok, see above.
            //       Decide what happens if a squash and an allocation land in
            //       the same cycle.
        end
    end
 
endmodule
 
