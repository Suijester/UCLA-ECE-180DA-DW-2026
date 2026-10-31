// ===========================================================================
// tb_golden.sv
//
// Cross-checks the SystemVerilog golden model against the vectors produced by
// tools/gen_vectors.py. If this passes, the spec, the Python model and the SV
// model all agree, and any mismatch you see later is in your RTL.
//
// Run it once after cloning so you know your toolchain reads the hex files
// correctly.
// ===========================================================================
module tb_golden;

    import accelerator_cnn_pkg::*;

    cnn_golden_model golden ();

    int total_errors = 0;
    int e;

    // image byte offset per vector; v5 lives in the second slot
    task automatic check(input string dir, input int offset);
        begin
            golden.load(dir);
            golden.run(offset);
            golden.self_check(dir, e);
            if (e == 0)
                $display("  ok   %-12s shift=%0d,%0d  pred=%0d",
                         dir, golden.shift1, golden.shift2, golden.pred);
            else
                $display("  FAIL %-12s %0d mismatches", dir, e);
            total_errors += e;
        end
    endtask

    initial begin
        $display("=== golden model vs generated vectors ===");

        // Sanity: the geometry constants must still describe the picture.
        if (FLAT != 48) begin
            $display("  FAIL FLAT is %0d, expected 48", FLAT);
            total_errors++;
        end
        if (TOTAL_MACS != 58080) begin
            $display("  FAIL TOTAL_MACS is %0d, expected 58080", TOTAL_MACS);
            total_errors++;
        end

        check("vectors/v0_box",    0);
        check("vectors/v1_ramp",   0);
        check("vectors/v2_random", 0);
        check("vectors/v3_zeros",  0);
        check("vectors/v4_ones",   0);
        check("vectors/v5_offset", 'h400);

        // The parameter memory must carry the magic word, or the vector files
        // and the package have drifted apart.
        golden.load("vectors/v0_box");
        if (golden.par[PAR_MAGIC] !== MAGIC) begin
            $display("  FAIL param magic %08h, expected %08h",
                     golden.par[PAR_MAGIC], MAGIC);
            total_errors++;
        end

        $display("");
        if (total_errors == 0) $display("GOLDEN PASS");
        else                   $display("GOLDEN FAIL (%0d errors)", total_errors);
        $finish;
    end

endmodule
