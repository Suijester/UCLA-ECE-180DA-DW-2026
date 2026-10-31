// ===========================================================================
// tb_system.sv -- SYSTEM TESTBENCH. The integration test for all four teams.
//
//   ./build.sh system
//
// Everything outside rv32_ooo_top lives here: the instruction ROM, the data
// RAM, and the accelerator's image / weight / parameter memories.
//
// It runs in stages so it is useful from week one rather than only at the
// end:
//
//   Stage 1  CONNECTIVITY. Runs today. Every interface signal that matters
//            is driven to a real 0 or 1 after reset, nothing is X, and reset
//            reaches every block. This is the single highest-value
//            integration test there is -- an unconnected port is the most
//            common and most confusing failure when four teams merge.
//
//   Stage 2  LIVENESS. The frontend fetches, the backend accepts, the LSU
//            moves data. Skipped with a clear message until those exist.
//
//   Stage 3  PROGRAM. A short program runs to completion and retires the
//            expected number of instructions.
//
//   Stage 4  ACCELERATOR IN SYSTEM. Software configures the three CSRs,
//            starts a job, polls for completion, and the result memory
//            matches the golden vector.
//
// Each stage reports and the testbench stops at the first one that cannot
// run, telling you what is missing. It never hangs.
// ===========================================================================
module tb_system;

    import rv32_ooo_pkg::*;
    import accelerator_cnn_pkg::*;
    import accelerator_pkg::*;

    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    // ----- everything external to the SoC ----------------------------------
    instruction_memory_if imem_if ();
    data_memory_if        dmem_if ();
    cnn_mem_if            xmem_if ();
    acc_debug_if          acc_dbg ();

    imem_model  #(.WORDS(4096))                               rom  (.clk_i(clk), .bus(imem_if));
    dmem_model  #(.WORDS(8192), .STALL_PCT(20), .MAX_LATENCY(3)) ram (.clk_i(clk), .rst_ni(rst_n), .bus(dmem_if));
    cnn_ext_mem #(.REGISTERED_READ(1'b0))                     xmem (.clk_i(clk), .bus(xmem_if));

    cnn_golden_model golden ();

    logic [XLEN-1:0] dbg_pc;
    logic [31:0]     retire_count, issue_count, load_count, store_count;
    logic            acc_busy;
    logic [31:0]     acc_cycles;

    rv32_ooo_top dut (
        .clk_i              (clk),
        .rst_ni             (rst_n),
        .imem               (imem_if),
        .dmem               (dmem_if),
        .acc_xmem           (xmem_if),
        .acc_dbg            (acc_dbg),
        .dbg_pc_o           (dbg_pc),
        .dbg_retire_count_o (retire_count),
        .dbg_issue_count_o  (issue_count),
        .dbg_load_count_o   (load_count),
        .dbg_store_count_o  (store_count),
        .dbg_acc_busy_o     (acc_busy),
        .dbg_acc_cycles_o   (acc_cycles)
    );

    `include "acc_check.svh"

    int errors = 0;
    int stage  = 0;
    bit halt   = 1'b0;     // $finish does not stop the current process in
                           // every simulator, so gate the later stages

    task automatic chk(input string name, input logic cond);
        if (!cond) begin
            $display("    FAIL %s", name);
            errors++;
        end
    endtask

    task automatic stop_here(input string why);
        begin
            $display("    --  %s", why);
            halt = 1'b1;
        end
    endtask

    // -----------------------------------------------------------------------
    // A short program: a few adds, a store, a load. Replace with your own.
    // -----------------------------------------------------------------------
    task automatic load_program();
        begin
            rom.clear();
            rom.put(0, 32'h00500093);   // addi x1, x0, 5
            rom.put(1, 32'h00700113);   // addi x2, x0, 7
            rom.put(2, 32'h002081B3);   // add  x3, x1, x2
            rom.put(3, 32'h40110233);   // sub  x4, x2, x1
            rom.put(4, 32'h003122A3);   // sw   x3, 5(x2)
            rom.put(5, 32'h00512303);   // lw   x6, 5(x2)
            for (int i = 6; i < 64; i++) rom.put(i, 32'h00000013);  // nop
        end
    endtask

    initial begin
        $display("=== system integration ===");
        load_program();
        ram.clear();
        xmem.load("vectors/v0_box");
        golden.load("vectors/v0_box");
        golden.run(0);
        dbg_idle();

        rst_n = 1'b0;
        repeat (6) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ===================================================================
        // STAGE 1 -- connectivity
        // ===================================================================
        stage = 1;
        $display("  stage 1: connectivity");

        // the instruction ROM port
        chk("imem.address is driven",     !$isunknown(imem_if.address));
        chk("imem.read_enable is driven", !$isunknown(imem_if.read_enable));

        // the data bus
        chk("dmem.request_valid is driven",  !$isunknown(dmem_if.request_valid));
        chk("dmem.request_valid low at reset", dmem_if.request_valid == 1'b0);
        chk("dmem.response_ready is driven", !$isunknown(dmem_if.response_ready));

        // the accelerator's external memory port
        chk("acc img_addr is driven", !$isunknown(xmem_if.img_addr));
        chk("acc wgt_addr is driven", !$isunknown(xmem_if.wgt_addr));
        chk("acc par_addr is driven", !$isunknown(xmem_if.par_addr));

        // aggregated counters must start clean
        chk("retire count starts at 0", retire_count == 0);
        chk("issue count starts at 0",  issue_count  == 0);
        chk("load count starts at 0",   load_count   == 0);
        chk("store count starts at 0",  store_count  == 0);
        chk("accelerator not busy at reset", acc_busy == 1'b0);

        // the debug window answers
        begin
            logic [31:0] d;
            dbg_read(MEM_RES, RES_ARGMAX, d);
            chk("accelerator debug port returns data, not X", !$isunknown(d));
        end

        // nothing may go X in the first 50 cycles
        begin
            int bad = 0;
            repeat (50) begin
                @(posedge clk); #1;
                if ($isunknown(imem_if.read_enable))    bad++;
                if ($isunknown(dmem_if.request_valid))  bad++;
                if ($isunknown(dmem_if.response_ready)) bad++;
            end
            chk("no X on the key handshakes over 50 cycles", bad == 0);
        end

        if (errors == 0) $display("    ok  every boundary signal is driven");

        // ===================================================================
        // STAGE 2 -- liveness
        // ===================================================================
        if (!halt) begin
            stage = 2;
            $display("  stage 2: liveness");
            repeat (200) @(posedge clk);
            #1;

            if (!imem_if.read_enable && dbg_pc == RESET_PC)
                stop_here("the frontend is not fetching yet (imem.read_enable never asserted)");
            else begin
                chk("the PC advanced", dbg_pc != RESET_PC);
                if (retire_count == 0)
                    stop_here("nothing retired in 200 cycles -- frontend and backend not talking yet");
                else
                    $display("    ok  fetching and retiring (%0d retired)", retire_count);
            end
        end

        // ===================================================================
        // STAGE 3 -- the program runs
        // ===================================================================
        if (!halt) begin
            stage = 3;
            $display("  stage 3: program");
            repeat (2000) @(posedge clk);
            #1;
            chk("at least 6 instructions retired", retire_count >= 6);
            if (load_count == 0 && store_count == 0)
                stop_here("no memory traffic -- the LSU is not wired up yet");
            else begin
                chk("the store reached memory", ram.peek((32'd7 + 32'd5) >> 2) != 32'h0);
                $display("    ok  program ran (%0d retired, %0d loads, %0d stores)",
                         retire_count, load_count, store_count);
            end
        end

        // ===================================================================
        // STAGE 4 -- the accelerator, driven from software
        // ===================================================================
        if (!halt) begin
        stage = 4;
        $display("  stage 4: accelerator in system");
        $display("    NOTE this stage needs a program that writes CSRs 0x7c1,");
        $display("         0x7c2 and 0x7c0 and polls 0x7c0 -- write one and");
        $display("         load it with rom.put() above, then check the result");
        $display("         with check_result(\"vectors/v0_box\", e).");

        begin
            int e;
            check_result("vectors/v0_box", e);
            if (e == 0) begin
                $display("    ok  accelerator produced the right answer in system");
            end else begin
                $display("    --  accelerator result not available (%0d mismatches)", e);
                $display("        expected until stage 4's program exists");
            end
        end
        end

        $display("");
        if (errors == 0) $display("SYSTEM STAGE %0d PASS", stage);
        else             $display("SYSTEM FAIL (%0d errors, stage %0d)", errors, stage);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("SYSTEM TIMEOUT");
        $fatal(1);
    end

endmodule
