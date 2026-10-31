// ===========================================================================
// tb_accelerator.sv -- ACCELERATOR TEAM'S TESTBENCH
//
// Runs against accelerator_top unmodified. The image, weight and parameter
// memories are EXTERNAL and live here, in cnn_ext_mem; the accelerator reads
// them over cnn_mem_if. The result comes back over acc_debug_if.
//
//   ./build.sh accel        your design in rtl/
//   ./build.sh accel-ref    the instructor reference
//
// What it checks:
//   1. all six vectors end to end
//   2. layer-by-layer agreement with the golden model on one vector
//   3. the CSR handshake -- done held until activate clears
//   4. repeated operation: the same job twice gives the same answer
//   5. a bad length raises error and completes rather than hanging
//   6. reset mid-job leaves the accelerator cleanly idle
// ===========================================================================
module tb_accelerator;

    import accelerator_cnn_pkg::*;

    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    csr_accelerator_if csr_if  ();
    cnn_mem_if         xmem_if ();
    acc_debug_if       acc_dbg ();

    // ----- external memories: the testbench owns these ---------------------
    cnn_ext_mem #(.REGISTERED_READ(1'b0)) xmem (
        .clk_i (clk),
        .bus   (xmem_if)
    );

    // ----- the golden model, for layer-by-layer checking -------------------
    cnn_golden_model golden ();

`ifdef USE_REF
    accelerator_ref dut (
`else
    accelerator_top dut (
`endif
        .clk_i        (clk),
        .rst_ni       (rst_n),
        .csr          (csr_if),
        .xmem         (xmem_if),
        .dbg          (acc_dbg),
        .dbg_busy_o   (),
        .dbg_cycles_o ()
    );

    `include "acc_check.svh"

    int total_errors = 0;
    int cyc;

    // -----------------------------------------------------------------------
    task automatic do_reset();
        begin
            csr_if.activate        = 1'b0;
            csr_if.memory_location = '0;
            csr_if.length          = '0;
            dbg_idle();
            rst_n = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    // Full CSR handshake: raise activate, wait for done, drop activate,
    // confirm done clears.
    task automatic run_job(input logic [31:0] loc, input logic [31:0] len,
                           output int cycles, output logic err);
        int guard;
        begin
            cycles = 0;
            guard  = 0;
            @(negedge clk);
            csr_if.memory_location = loc;
            csr_if.length          = len;
            csr_if.activate        = 1'b1;

            while (!csr_if.done && guard < 2_000_000) begin
                @(posedge clk); cycles++; guard++;
            end
            if (guard >= 2_000_000) begin
                $display("    FAIL job never asserted done");
                total_errors++;
            end
            err = csr_if.error;

            // done must be a LEVEL that survives until activate drops
            repeat (3) @(posedge clk);
            if (!csr_if.done) begin
                $display("    FAIL done did not hold while activate was still high");
                total_errors++;
            end

            @(negedge clk);
            csr_if.activate = 1'b0;
            guard = 0;
            while (csr_if.done && guard < 1000) begin
                @(posedge clk); guard++;
            end
            if (csr_if.done) begin
                $display("    FAIL done did not clear after activate dropped");
                total_errors++;
            end
        end
    endtask

    task automatic check_vector(input string dir, input logic [31:0] offset);
        int e;
        logic err;
        begin
            xmem.load(dir);
            run_job(offset, IMG_PIXELS, cyc, err);
            if (err) begin
                $display("    FAIL %s raised error unexpectedly", dir);
                total_errors++;
            end
            check_result(dir, e);
            total_errors += e;
            if (e == 0) $display("  ok   %-20s %7d cycles", dir, cyc);
            else        $display("  FAIL %-20s %0d mismatches", dir, e);
        end
    endtask

    // -----------------------------------------------------------------------
    initial begin
        $display("=== accelerator ===");
        do_reset();

        // ---- 1. all six vectors -------------------------------------------
        check_vector("vectors/v0_box",    32'h000);
        check_vector("vectors/v1_ramp",   32'h000);
        check_vector("vectors/v2_random", 32'h000);
        check_vector("vectors/v3_zeros",  32'h000);
        check_vector("vectors/v4_ones",   32'h000);
        check_vector("vectors/v5_offset", 32'h400);   // second image slot

        // ---- 2. layer by layer, against the golden model -------------------
        //
        // IMPORTANT: the activation buffers are reused. After a COMPLETE job
        //
        //     ACT_A holds conv2's output   (a2) -- conv1's has been overwritten
        //     ACT_B holds pool2's output   (p2) -- pool1's has been overwritten
        //
        // so only layers 3 and 4 are meaningful here.
        //
        // Layers 1 and 2 are checkable during BRING-UP: while you have only
        // built conv1, nothing overwrites ACT_A, so running this testbench
        // and calling check_layer(1, e) will compare your conv1 output
        // against golden.a1[]. Same for pool1 with check_layer(2, e) once
        // pool1 exists but conv2 does not. That is why the spec tells you to
        // build one layer at a time.
        begin
            int e3, e4;
            logic err;
            xmem.load("vectors/v2_random");
            golden.load("vectors/v2_random");
            golden.run(0);
            run_job(32'h000, IMG_PIXELS, cyc, err);
            check_layer(3, e3);
            check_layer(4, e4);
            total_errors += e3 + e4;
            if (e3 + e4 == 0)
                $display("  ok   layer-by-layer       conv2 and pool2 match the golden model");
            else
                $display("  FAIL layer-by-layer       conv2=%0d pool2=%0d mismatches", e3, e4);
        end

        // ---- 4. repeated operation ----------------------------------------
        begin
            int e;
            logic err;
            xmem.load("vectors/v0_box");
            run_job(32'h000, IMG_PIXELS, cyc, err);
            run_job(32'h000, IMG_PIXELS, cyc, err);
            check_result("vectors/v0_box", e);
            total_errors += e;
            if (e == 0) $display("  ok   repeated job          %7d cycles", cyc);
            else $display("  FAIL repeated job gave a different answer (%0d mismatches)", e);
        end

        // ---- 5. bad length -------------------------------------------------
        begin
            logic err;
            run_job(32'h000, 32'd123, cyc, err);
            if (!err) begin
                $display("  FAIL length=123 should have raised error");
                total_errors++;
            end else $display("  ok   bad length raises error");
        end

        // ...and the accelerator must recover afterwards
        check_vector("vectors/v1_ramp", 32'h000);

        // ---- 6. reset in the middle of a job -------------------------------
        begin
            int e;
            logic err;
            xmem.load("vectors/v0_box");
            @(negedge clk);
            csr_if.memory_location = 32'h000;
            csr_if.length          = IMG_PIXELS;
            csr_if.activate        = 1'b1;
            repeat (500) @(posedge clk);       // interrupt mid-inference
            do_reset();
            if (csr_if.done || csr_if.error) begin
                $display("  FAIL done/error still set after reset");
                total_errors++;
            end
            run_job(32'h000, IMG_PIXELS, cyc, err);
            check_result("vectors/v0_box", e);
            total_errors += e;
            if (e == 0) $display("  ok   recovers from mid-job reset");
            else        $display("  FAIL wrong answer after mid-job reset (%0d)", e);
        end

        $display("");
        if (total_errors == 0) $display("ACCEL PASS");
        else                   $display("ACCEL FAIL (%0d errors)", total_errors);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("ACCEL TIMEOUT");
        $fatal(1);
    end

endmodule
