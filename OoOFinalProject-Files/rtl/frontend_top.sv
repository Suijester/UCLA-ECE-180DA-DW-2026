// ===========================================================================
// frontend_top.sv -- FRONTEND TEAM'S TOP MODULE
//
// Owns: fetch, decode, rename, the ROB, dispatch and retirement.
//
// This file defines the frontend's BOUNDARY. The ports and interface modports
// here are fixed -- the backend and memory teams build against them, and the
// system top instantiates this by name. Everything inside is yours.
//
//   instruction_memory_if.frontend   fetch two instructions per cycle from ROM
//   frontend_backend_if.frontend     dispatch out, completion/branch in,
//                                    ROB head and retirement out
//
// Reset is active-low and synchronous.
// ===========================================================================
module frontend_top
    import rv32_ooo_pkg::*;
    import instruction_memory_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    // to the instruction ROM (the memory team / testbench provides it)
    instruction_memory_if.frontend imem,

    // to the backend
    frontend_backend_if.frontend   fb,

    // ----- observability, for the testbench and for your own debug ---------
    output logic [XLEN-1:0] dbg_pc_o,            // current fetch PC
    output logic            dbg_rob_full_o,
    output logic            dbg_rob_empty_o,
    output logic [31:0]     dbg_retire_count_o   // instructions retired since reset
);

    // =======================================================================
    // TODO -- FRONTEND TEAM
    //
    //  1. FETCH
    //     Drive imem.address (word-aligned byte address) and imem.read_enable.
    //     The ROM is synchronous with a fixed one-cycle latency and NO
    //     handshake: on an enabled clock edge it samples the address and
    //     updates imem.data / imem.error. A disabled edge HOLDS the previous
    //     output. imem.data[31:0] is the instruction at `address`,
    //     imem.data[63:32] the one at `address+4`.
    //
    //  2. DECODE into decoded_uop_t. The struct is deliberately explicit --
    //     fill in uop_class, alu_op, operand selects, branch_op, mem_cmd,
    //     csr_cmd and the immediate so the backend never re-decodes.
    //
    //  3. RENAME to physical registers, producing renamed_uop_t.
    //
    //  4. DISPATCH up to two per cycle on fb.dispatch_count /
    //     fb.dispatch_bundle. The backend accepts a PREFIX: it returns
    //     fb.dispatch_accept_count, which may be 0, 1 or 2 and is never more
    //     than you offered. If it accepts 1 of 2, lane1 must be re-offered
    //     next cycle -- as lane0.
    //
    //  5. ROB: allocate on dispatch, mark done on fb.completion_valid_*,
    //     retire in order from the head. Drive fb.rob_head_tag,
    //     fb.retire_valid and fb.retire_tag.
    //
    //  6. BRANCH RECOVERY: when fb.branch_resolve_valid && fb.branch_mispredict,
    //     flush younger instructions and redirect fetch to
    //     fb.branch_result_pc. The backend emits this once, whether or not
    //     dispatch was accepted that cycle, and it guarantees
    //     dispatch_accept_count == 0 on that cycle.
    //
    //  Note rob_tag_t carries a GENERATION as well as an index. Compare both.
    //  Matching only the index will accept a stale completion after the slot
    //  has been reused, and that bug appears as a random hang under load.
    // =======================================================================

    // -----------------------------------------------------------------------
    // Placeholder so the design elaborates and the testbench runs while you
    // build. Delete all of this.
    // -----------------------------------------------------------------------
    logic [XLEN-1:0] pc_q;
    logic [31:0]     retire_count_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            pc_q           <= RESET_PC;
            retire_count_q <= '0;
        end else begin
            pc_q <= pc_q;                       // TODO: advance fetch
            if (fb.retire_valid) retire_count_q <= retire_count_q + 32'd1;
        end
    end

    assign imem.address     = pc_q;
    assign imem.read_enable = 1'b0;             // TODO: enable fetch

    assign fb.dispatch_count  = 2'd0;
    assign fb.dispatch_bundle = '0;
    assign fb.rob_head_tag    = '0;
    assign fb.retire_valid    = 1'b0;
    assign fb.retire_tag      = '0;

    assign dbg_pc_o           = pc_q;
    assign dbg_rob_full_o     = 1'b0;
    assign dbg_rob_empty_o    = 1'b1;
    assign dbg_retire_count_o = retire_count_q;

endmodule
