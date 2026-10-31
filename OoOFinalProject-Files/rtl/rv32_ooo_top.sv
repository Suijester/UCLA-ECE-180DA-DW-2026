// ===========================================================================
// rv32_ooo_top.sv -- SYSTEM TOP. Instantiates all four teams' blocks and the
// interfaces between them.
//
// NOBODY OWNS THIS FILE ALONE. Changing a port here changes somebody else's
// boundary, so changes go through all four teams.
//
//                      ┌─────────────────────────────────────────┐
//   instruction_memory │                                         │
//   ◀──────────────────┤  frontend_top ◀── frontend_backend_if ──▶│
//                      │       │                   │             │
//                      │       │             backend_top         │
//                      │       │              │          │       │
//                      │       │   backend_memory_if  csr_accel_if
//                      │       │              │          │       │
//                      │       │        memory_top   accelerator_top
//                      │       │              │          │       │
//   data_memory_if  ◀──┼───────┼──────────────┘          │       │
//   cnn_mem_if      ◀──┼──────────────────────────────────┘      │
//   acc_debug_if    ◀──┼──────────────────────────────────────── │
//                      └─────────────────────────────────────────┘
//
// Everything crossing the boundary is a memory the testbench provides:
//   instruction_memory_if  the instruction ROM
//   data_memory_if         the data RAM
//   cnn_mem_if             the accelerator's image / weight / parameter
//                          memories
//   acc_debug_if           read-only window into the accelerator's result
//
// Reset is active-low and synchronous, shared by every block.
// ===========================================================================
module rv32_ooo_top
    import rv32_ooo_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    instruction_memory_if.frontend imem,
    data_memory_if.client          dmem,
    cnn_mem_if.accelerator         acc_xmem,
    acc_debug_if.target            acc_dbg,

    // ----- observability, aggregated for the system testbench --------------
    output logic [XLEN-1:0] dbg_pc_o,
    output logic [31:0]     dbg_retire_count_o,
    output logic [31:0]     dbg_issue_count_o,
    output logic [31:0]     dbg_load_count_o,
    output logic [31:0]     dbg_store_count_o,
    output logic            dbg_acc_busy_o,
    output logic [31:0]     dbg_acc_cycles_o
);

    // -----------------------------------------------------------------------
    // Internal interfaces. These are the team boundaries.
    // -----------------------------------------------------------------------
    frontend_backend_if fb_if   (.clk_i(clk_i), .rst_ni(rst_ni));
    backend_memory_if   bm_if   ();
    csr_accelerator_if  acc_csr ();

    logic rob_full, rob_empty, mem_outstanding;

    // -----------------------------------------------------------------------
    // FRONTEND -- fetch, decode, rename, ROB, retire
    // -----------------------------------------------------------------------
    frontend_top u_frontend (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        .imem               (imem),
        .fb                 (fb_if),
        .dbg_pc_o           (dbg_pc_o),
        .dbg_rob_full_o     (rob_full),
        .dbg_rob_empty_o    (rob_empty),
        .dbg_retire_count_o (dbg_retire_count_o)
    );

    // -----------------------------------------------------------------------
    // BACKEND -- issue, execute, PRF, CSR unit
    // -----------------------------------------------------------------------
    backend_top u_backend (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .fb                (fb_if),
        .mem               (bm_if),
        .acc_csr           (acc_csr),
        .dbg_issue_count_o (dbg_issue_count_o),
        .dbg_acc_busy_o    (dbg_acc_busy_o)
    );

    // -----------------------------------------------------------------------
    // MEMORY -- load/store unit, master of the data bus
    // -----------------------------------------------------------------------
    memory_top u_memory (
        .clk_i             (clk_i),
        .rst_ni            (rst_ni),
        .be                (bm_if),
        .dmem              (dmem),
        .dbg_load_count_o  (dbg_load_count_o),
        .dbg_store_count_o (dbg_store_count_o),
        .dbg_outstanding_o (mem_outstanding)
    );

    // -----------------------------------------------------------------------
    // ACCELERATOR -- MNIST CNN, driven by the backend's custom CSRs
    // -----------------------------------------------------------------------
    accelerator_top u_accelerator (
        .clk_i        (clk_i),
        .rst_ni       (rst_ni),
        .csr          (acc_csr),
        .xmem         (acc_xmem),
        .dbg          (acc_dbg),
        .dbg_busy_o   (),
        .dbg_cycles_o (dbg_acc_cycles_o)
    );

endmodule
