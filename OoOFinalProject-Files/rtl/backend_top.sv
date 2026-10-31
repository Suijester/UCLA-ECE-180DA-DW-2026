// ===========================================================================
// backend_top.sv -- BACKEND TEAM'S TOP MODULE
//
// Owns: issue queues, the physical register file, the ALU and branch units,
// the CSR unit, and the handoff of memory operations to the memory team.
//
// This file defines the backend's BOUNDARY. Three interfaces:
//
//   frontend_backend_if.backend    dispatch in; completion, branch
//                                  resolution out
//   backend_memory_if.backend      issue loads/stores to the LSU, take
//                                  results back
//   csr_accelerator_if.csr         drive the accelerator from the three
//                                  custom CSRs
//
// The CSR unit is yours, and it is the integration point with the
// accelerator team. Get the protocol in section 3.2 of the accelerator spec
// right: `done` is a level that holds until `activate` clears, not a pulse.
// ===========================================================================
module backend_top
    import rv32_ooo_pkg::*;
    import accelerator_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    frontend_backend_if.backend    fb,
    backend_memory_if.backend      mem,
    csr_accelerator_if.csr         acc_csr,

    // ----- observability ---------------------------------------------------
    output logic [31:0] dbg_issue_count_o,     // uops issued since reset
    output logic        dbg_acc_busy_o         // an accelerator job is running
);

    // =======================================================================
    // TODO -- BACKEND TEAM
    //
    //  1. ACCEPT DISPATCH. Read fb.dispatch_count and fb.dispatch_bundle,
    //     return fb.dispatch_accept_count. You may accept 0, 1 or 2, but
    //     only as a PREFIX: accepting lane1 without lane0 is illegal.
    //
    //  2. WAKEUP / SELECT / EXECUTE. Track operand readiness, read the PRF,
    //     run the ALU. Use decoded.operand_a_sel / operand_b_sel rather than
    //     re-decoding the instruction.
    //
    //  3. COMPLETE. Drive fb.completion_valid_0/1 and fb.completion_0/1 with
    //     execution_result_t. Note the two fields do different jobs: a
    //     completion always marks its ROB entry done, while writeback_valid
    //     separately says whether the PRF must be updated. A store completes
    //     but writes no register.
    //
    //  4. BRANCH RESOLUTION. Emit fb.branch_resolve_valid once per resolved
    //     branch, with fb.branch_mispredict, fb.branch_result_tag and
    //     fb.branch_result_pc. On that cycle you must set
    //     fb.dispatch_accept_count to 0 -- the interface asserts this.
    //
    //  5. MEMORY OPS. Hand loads and stores to the LSU over `mem`. Only
    //     non-speculative, ROB-head operations may issue: compare
    //     fb.rob_head_tag against the uop's tag. Drive mem.rob_head_tag so
    //     the LSU can check too.
    //
    //  6. THE CSR UNIT -- the accelerator integration point.
    //
    //     csrw 0x7c1 (CSR_ACC_MEMORY_LOCATION) -> acc_csr.memory_location
    //     csrw 0x7c2 (CSR_ACC_LENGTH)          -> acc_csr.length
    //     csrw 0x7c0 (CSR_ACC_ACTIVATE) bit 0  -> acc_csr.activate
    //
    //     CSR writes must take effect at RETIREMENT, not at execute: a CSR
    //     write on a mispredicted path must never start the accelerator.
    //     Use fb.retire_valid / fb.retire_tag.
    //
    //     On acc_csr.done: clear ACTIVATE bit 0 (which drops acc_csr.activate
    //     and releases the accelerator back to idle) and latch acc_csr.error
    //     into ACTIVATE bit 1, which is sticky and read-only to software.
    //
    //     csrr 0x7c0 returns {.., error, activate} so software can poll.
    //
    //  OPEN ITEM: there is currently no path for the accelerator's RESULT to
    //  reach software -- csr_accelerator_if carries only done and error. See
    //  section 11.1 of the accelerator spec. Settle this with the
    //  accelerator team before integration; the likely answer is a read-only
    //  CSR at 0x7c3.
    // =======================================================================

    // -----------------------------------------------------------------------
    // Placeholder. Delete all of this.
    // -----------------------------------------------------------------------
    logic [31:0] issue_count_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) issue_count_q <= '0;
        else if (mem.issue_valid && mem.issue_ready)
            issue_count_q <= issue_count_q + 32'd1;
    end

    assign fb.dispatch_accept_count = 2'd0;
    assign fb.completion_valid_0    = 1'b0;
    assign fb.completion_valid_1    = 1'b0;
    assign fb.completion_0          = '0;
    assign fb.completion_1          = '0;
    assign fb.branch_resolve_valid  = 1'b0;
    assign fb.branch_mispredict     = 1'b0;
    assign fb.branch_result_tag     = '0;
    assign fb.branch_result_pc      = '0;

    assign mem.issue_valid  = 1'b0;
    assign mem.issue_uop    = '0;
    assign mem.source_1     = '0;
    assign mem.source_2     = '0;
    assign mem.rob_head_tag = '0;
    assign mem.result_ready = 1'b1;

    assign acc_csr.activate        = 1'b0;
    assign acc_csr.memory_location = '0;
    assign acc_csr.length          = '0;

    assign dbg_issue_count_o = issue_count_q;
    assign dbg_acc_busy_o    = acc_csr.activate && !acc_csr.done;

endmodule
