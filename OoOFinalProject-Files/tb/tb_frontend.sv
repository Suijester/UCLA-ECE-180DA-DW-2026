// ===========================================================================
// tb_frontend.sv -- FRONTEND TEAM'S TESTBENCH
//
//   ./build.sh frontend
//
// The frontend is tested against two things it does not own: an instruction
// ROM model, and a STUB BACKEND that lives in this file. The stub accepts
// dispatch, completes instantly, and never mispredicts -- just enough to let
// the frontend run.
//
// Stage 1 runs today and checks reset and interface hygiene. Stages 2 and 3
// check real behaviour and are skipped until your frontend fetches; the
// testbench tells you which stage it reached.
// ===========================================================================
module tb_frontend;

    import rv32_ooo_pkg::*;
    import instruction_memory_pkg::*;

    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    instruction_memory_if imem_if ();
    frontend_backend_if   fb_if (.clk_i(clk), .rst_ni(rst_n));

    imem_model #(.WORDS(1024)) rom (.clk_i(clk), .bus(imem_if));

    logic [XLEN-1:0] dbg_pc;
    logic            rob_full, rob_empty;
    logic [31:0]     retire_count;

    frontend_top dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .imem               (imem_if),
        .fb                 (fb_if),
        .dbg_pc_o           (dbg_pc),
        .dbg_rob_full_o     (rob_full),
        .dbg_rob_empty_o    (rob_empty),
        .dbg_retire_count_o (retire_count)
    );

    // -----------------------------------------------------------------------
    // STUB BACKEND. Accepts everything the frontend offers and completes it
    // on the next cycle. Replace with the real backend in tb_system.
    //
    // `accept_limit` lets the test apply backpressure: 0, 1 or 2 per cycle.
    // -----------------------------------------------------------------------
    logic [1:0] accept_limit = 2'd2;

    assign fb_if.dispatch_accept_count =
        (fb_if.dispatch_count < accept_limit) ? fb_if.dispatch_count : accept_limit;

    // complete one cycle after acceptance, in order
    renamed_uop_t pend0_q, pend1_q;
    logic         pend0_v_q, pend1_v_q;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pend0_v_q <= 1'b0;
            pend1_v_q <= 1'b0;
        end else begin
            pend0_v_q <= (fb_if.dispatch_accept_count >= 1);
            pend1_v_q <= (fb_if.dispatch_accept_count >= 2);
            pend0_q   <= fb_if.dispatch_bundle.lane0;
            pend1_q   <= fb_if.dispatch_bundle.lane1;
        end
    end

    assign fb_if.completion_valid_0 = pend0_v_q;
    assign fb_if.completion_valid_1 = pend1_v_q;
    assign fb_if.completion_0 = '{rob_tag: pend0_q.rob_tag,
                                  writeback_valid: pend0_q.has_destination,
                                  writeback_pdst: pend0_q.pdst,
                                  value: 32'hDEAD_0000,
                                  under_unresolved_branch: 1'b0};
    assign fb_if.completion_1 = '{rob_tag: pend1_q.rob_tag,
                                  writeback_valid: pend1_q.has_destination,
                                  writeback_pdst: pend1_q.pdst,
                                  value: 32'hDEAD_0001,
                                  under_unresolved_branch: 1'b0};

    assign fb_if.branch_resolve_valid = 1'b0;
    assign fb_if.branch_mispredict    = 1'b0;
    assign fb_if.branch_result_tag    = '0;
    assign fb_if.branch_result_pc     = '0;

    // -----------------------------------------------------------------------
    int errors = 0;
    int stage  = 0;
    bit halt   = 1'b0;      // $finish does not stop the current process in
                            // every simulator, so gate the later stages

    task automatic chk(input string name, input logic cond);
        if (!cond) begin
            $display("  FAIL %s", name);
            errors++;
        end
    endtask

    // A handful of NOPs followed by a few adds. Enough to fetch and retire.
    task automatic load_program();
        begin
            rom.clear();
            for (int i = 0; i < 16; i++)
                rom.put(i, 32'h00100093 | (i << 20));   // addi x1, x0, i
        end
    endtask

    initial begin
        $display("=== frontend ===");
        load_program();
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ---- stage 1: reset and interface hygiene --------------------------
        stage = 1;
        chk("dispatch_count is not X after reset",
            !$isunknown(fb_if.dispatch_count));
        chk("dispatch_count <= 2 after reset", fb_if.dispatch_count <= 2);
        chk("retire_valid is not X after reset",
            !$isunknown(fb_if.retire_valid));
        chk("retire count starts at 0", retire_count == 0);
        chk("imem.read_enable is not X", !$isunknown(imem_if.read_enable));
        chk("imem.address is not X", !$isunknown(imem_if.address));
        chk("PC starts at RESET_PC", dbg_pc == RESET_PC);
        chk("ROB reports empty after reset", rob_empty);
        if (errors == 0) $display("  ok   stage 1: reset and interface hygiene");

        // ---- stage 2: does it fetch? ---------------------------------------
        repeat (20) @(posedge clk);
        #1;
        if (!imem_if.read_enable) begin
            $display("  --   stage 2 skipped: imem.read_enable never asserted");
            $display("       (expected while frontend_top is still a skeleton)");
            halt = 1'b1;
        end else begin
            stage = 2;
            chk("PC advanced past RESET_PC", dbg_pc != RESET_PC);
            if (errors == 0) $display("  ok   stage 2: fetch is running");
        end

        // ---- stage 3: dispatch and retire ----------------------------------
        if (!halt) begin
        repeat (200) @(posedge clk);
        #1;
        stage = 3;
        chk("something was dispatched", fb_if.dispatch_count != 0 || retire_count != 0);
        chk("instructions retired", retire_count > 0);

        // backpressure: the backend stops accepting, nothing may be lost
        begin
            int unsigned prev_retire;
            @(negedge clk); accept_limit = 2'd0;
            repeat (20) @(posedge clk);
            #1 prev_retire = retire_count;
            repeat (20) @(posedge clk);
            #1 chk("no retirement while the backend accepts nothing",
                   retire_count == prev_retire);
            @(negedge clk); accept_limit = 2'd2;
            repeat (50) @(posedge clk);
            #1 chk("retirement resumes when backpressure lifts",
                   retire_count > prev_retire);
        end
        end

        $display("");
        if (errors == 0) $display("FRONTEND STAGE %0d PASS", stage);
        else             $display("FRONTEND FAIL (%0d errors, reached stage %0d)",
                                  errors, stage);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FRONTEND TIMEOUT");
        $fatal(1);
    end

endmodule
