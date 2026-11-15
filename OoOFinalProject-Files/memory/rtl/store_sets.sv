import mem_pkg::*;
import rv32_ooo_pkg::*;

// store sets memory-dependence predictor (Chrysos & Emer, ISCA 1998)
//
// predicts which older store a load will read from, so the load waits only for
// that store instead of every older store (STORE_SET_DISAMBIG mode).
//
//   SSIT (store set id table): SSIT_SIZE entries, indexed by PC -> {valid, set id}
//   LFST (last fetched store table): LFST_SIZE entries, indexed by set id
//        -> {valid, SQ pointer of the last dispatched store in that set}
//
// dispatch, per lane (2-wide, lane 0 older than lane 1):
//   load  : SSIT hit and LFST valid -> wait for that store
//   store : SSIT hit and LFST valid -> wait for that store (stores in a set are
//           chained, as in the paper); then this store becomes the set's LFST entry
// store issued (address + data known): if the set's LFST still points at it,
//   invalidate the LFST entry (nothing younger needs to wait for it)
// violation: put the load's and the store's PCs in the same set
//   neither in a set -> both get a new set id
//   one in a set     -> the other joins it
//   both in sets     -> both take the smaller id (merge)
// every SSIT_CLEAR_CYCLES cycles the SSIT is cleared so stale pairs stop
//   costing waits
// recovery: a squashed store must not stay in the LFST (mispredict mask or full flush)
//
// wait tags are SQ POINTERS (st_ptr_t, with the wrap bit), not indices: if the
// store has already drained and its slot was reused --> the load queue can tell
// by comparing against the SQ head and stop waiting.

module store_sets #(
    parameter int SSIT_CLEAR_CYCLES = 16384
) (
    input logic clk,
    input logic rst_n,

    //dispatch (from the accepted dispatch bundle, lane 0 is older)
    input logic [1:0] disp_valid,
    input logic [1:0] disp_is_load,
    input logic [1:0] disp_is_store,
    input logic [XLEN-1:0] disp_pc [2],
    input st_ptr_t disp_st_ptr [2],          // SQ slot given to a store lane

    output logic [1:0] disp_wait_valid,      // this lane must wait for a store
    output st_ptr_t disp_wait_st_ptr [2],    

    // a store issued (its address and data are now in the SQ)
    input logic st_issue_valid,
    input st_ptr_t st_issue_ptr,

    // memory-order violation detected (from the LQ/SQ search)
    input logic viol_valid,
    input logic [XLEN-1:0] viol_load_pc,
    input logic [XLEN-1:0] viol_store_pc,

    // recovery
    input logic flush_all,
    input logic [SQ_SIZE-1:0] sq_squash_mask  // SQ slots freed by a mispredict this cycle
);

    localparam int SSIT_IDX_BITS = $clog2(SSIT_SIZE);
    localparam int SQ_IDX_BITS = $clog2(SQ_SIZE);

    // tables
    logic [SSIT_SIZE-1:0] ssit_valid;
    ssit_t ssit_id [SSIT_SIZE];

    logic [LFST_SIZE-1:0] lfst_valid;
    st_ptr_t lfst_st_ptr [LFST_SIZE];

    // set id each in-flight store was dispatched with (so issue can find its LFST entry)
    logic [SQ_SIZE-1:0] sq_has_set;
    ssit_t sq_set_id [SQ_SIZE];

    // PC -> SSIT index (instructions are 4-byte aligned, so skip pc[1:0])
    function automatic ssit_ptr_t ssit_index(input logic [XLEN-1:0] pc);
        return pc[2 +: SSIT_IDX_BITS];
    endfunction

    // ---------------------------------------------------------------------
    // dispatch lookup
    // ---------------------------------------------------------------------
    ssit_ptr_t disp_idx [2];
    logic [1:0] disp_in_set;
    ssit_t disp_set [2];

    //combinational logic to determine if the dispatch lanes are in a set and which set they belong to
    always_comb begin : DISPATCH_LOOKUP
        for (int l = 0; l < 2; l++) begin
            disp_idx[l] = ssit_index(disp_pc[l]);
            disp_in_set[l] = disp_valid[l] && (disp_is_load[l] || disp_is_store[l]) && ssit_valid[disp_idx[l]];
            disp_set[l] = ssit_id[disp_idx[l]];
        end
    end

    // combinational logic to determine if a dispatch lane must wait for a store in its set (if any)
    always_comb begin : DISPATCH_WAIT
        // lane 0: only the ttable
        disp_wait_valid[0] = disp_in_set[0] && lfst_valid[disp_set[0]];
        disp_wait_st_ptr[0] = lfst_st_ptr[disp_set[0]];

        // lane 1: a store in lane 0 of the same set is newer than the table entry
        if (disp_in_set[1] && disp_in_set[0] && disp_is_store[0] && (disp_set[0] == disp_set[1])) begin
            disp_wait_valid[1] = 1'b1;
            disp_wait_st_ptr[1] = disp_st_ptr[0];
        end else begin
            disp_wait_valid[1] = disp_in_set[1] && lfst_valid[disp_set[1]];
            disp_wait_st_ptr[1] = lfst_st_ptr[disp_set[1]];
        end
    end

    // ---------------------------------------------------------------------
    // violation training: how store sets learns which loads depend on which stores.
    // ---------------------------------------------------------------------
    ssit_ptr_t viol_ld_idx, viol_st_idx;
    assign viol_ld_idx = ssit_index(viol_load_pc);
    assign viol_st_idx = ssit_index(viol_store_pc);

    logic viol_ld_in_set, viol_st_in_set;
    assign viol_ld_in_set = ssit_valid[viol_ld_idx];
    assign viol_st_in_set = ssit_valid[viol_st_idx];

    ssit_t next_new_id;    // round-robin source of fresh set ids
    ssit_t viol_set;

    always_comb begin : VIOLATION_SET
        if (viol_ld_in_set && viol_st_in_set)
            viol_set = (ssit_id[viol_ld_idx] < ssit_id[viol_st_idx]) ? ssit_id[viol_ld_idx] : ssit_id[viol_st_idx];
        else if (viol_ld_in_set)
            viol_set = ssit_id[viol_ld_idx];
        else if (viol_st_in_set)
            viol_set = ssit_id[viol_st_idx];
        else
            viol_set = next_new_id;
    end

    // ---------------------------------------------------------------------
    // periodic SSIT clear
    // ---------------------------------------------------------------------
    logic [$clog2(SSIT_CLEAR_CYCLES)-1:0] clear_count;
    logic clear_now;
    assign clear_now = (clear_count == '1);

    // ---------------------------------------------------------------------
    // state update
    // ---------------------------------------------------------------------
    st_idx_t issue_idx;
    assign issue_idx = st_issue_ptr[SQ_IDX_BITS-1:0];

    always_ff @(posedge clk) begin : SSIT_UPDATE
        if (!rst_n) begin
            ssit_valid <= '0;
            clear_count <= '0;
            next_new_id <= '0;
        end else begin
            clear_count <= clear_count + 1'b1;

            if (clear_now) begin
                ssit_valid <= '0;
            end else if (viol_valid) begin
                ssit_valid[viol_ld_idx] <= 1'b1;
                ssit_valid[viol_st_idx] <= 1'b1;
                ssit_id[viol_ld_idx] <= viol_set;
                ssit_id[viol_st_idx] <= viol_set;
                if (!viol_ld_in_set && !viol_st_in_set)
                    next_new_id <= next_new_id + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin : LFST_UPDATE
        if (!rst_n || flush_all) begin
            lfst_valid <= '0;
            sq_has_set <= '0;
        end else begin
            // 1. squashed stores leave the LFST
            for (int s = 0; s < LFST_SIZE; s++) begin
                if (lfst_valid[s] && sq_squash_mask[lfst_st_ptr[s][SQ_IDX_BITS-1:0]])
                    lfst_valid[s] <= 1'b0;
            end
            sq_has_set <= sq_has_set & ~sq_squash_mask;

            // 2. an issued store no longer needs to be waited on
            if (st_issue_valid && sq_has_set[issue_idx]) begin
                if (lfst_valid[sq_set_id[issue_idx]] && (lfst_st_ptr[sq_set_id[issue_idx]] == st_issue_ptr))
                    lfst_valid[sq_set_id[issue_idx]] <= 1'b0;
                sq_has_set[issue_idx] <= 1'b0;
            end

            // 3. newly dispatched stores become their set's last store
            //    (written last so they win over 1 and 2; lane 1 is younger, so it wins over lane 0)
            for (int l = 0; l < 2; l++) begin
                if (disp_in_set[l] && disp_is_store[l]) begin
                    lfst_valid[disp_set[l]] <= 1'b1;
                    lfst_st_ptr[disp_set[l]] <= disp_st_ptr[l];
                    sq_has_set[disp_st_ptr[l][SQ_IDX_BITS-1:0]] <= 1'b1;
                    sq_set_id[disp_st_ptr[l][SQ_IDX_BITS-1:0]] <= disp_set[l];
                end
            end
        end
    end

    // TODO: a violation in the same cycle as a dispatch of the same PCs uses the
    //       old SSIT (the new set applies from the next dispatch); fine for a
    //       predictor, but note it in tests.
    // TODO: decide with the LQ owner how a load treats a wait pointer whose store
    //       has already drained (compare with the SQ head, stop waiting).

endmodule
