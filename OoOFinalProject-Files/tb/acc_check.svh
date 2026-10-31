// ===========================================================================
// acc_check.svh -- result readback and grading for the accelerator.
//
// Include inside a testbench module that already has in scope:
//     logic        clk;
//     acc_debug_if acc_dbg ();     connected to the accelerator's dbg port
//
// (It is an include file rather than a module because calling a task that
// lives in another module is poorly supported across simulators.)
// ===========================================================================

logic [31:0] chk_scratch [64];

task automatic dbg_read(input mem_sel_e sel, input int addr,
                        output logic [31:0] data);
    @(negedge clk);
    acc_dbg.sel  = sel;
    acc_dbg.addr = addr[15:0];
    #1;
    data = acc_dbg.rdata;
endtask

task automatic dbg_idle();
    acc_dbg.sel  = MEM_RES;
    acc_dbg.addr = '0;
endtask

task automatic print_result();
    logic [31:0] d;
    begin
        dbg_read(MEM_RES, RES_ARGMAX, d);
        $display("    predicted digit = %0d", d);
        for (int o = 0; o < FC_O; o++) begin
            dbg_read(MEM_RES, RES_LOGIT + o, d);
            $display("    logit[%0d] = %0d", o, $signed(d));
        end
    end
endtask

// Compare the result memory against a vector's expected.hex.
task automatic check_result(input string dir, output int errors);
    logic [31:0] got;
    begin
        errors = 0;
        for (int i = 0; i < 64; i++) chk_scratch[i] = '0;
        $readmemh({dir, "/expected.hex"}, chk_scratch, 0, RES_WORDS - 1);

        for (int o = 0; o < FC_O; o++) begin
            dbg_read(MEM_RES, RES_LOGIT + o, got);
            if (got !== chk_scratch[RES_LOGIT + o]) begin
                $display("    FAIL logit[%0d]: got %0d, expected %0d", o,
                         $signed(got), $signed(chk_scratch[RES_LOGIT + o]));
                errors++;
            end
        end
        dbg_read(MEM_RES, RES_ARGMAX, got);
        if (got !== chk_scratch[RES_ARGMAX]) begin
            $display("    FAIL predicted digit: got %0d, expected %0d",
                     got, chk_scratch[RES_ARGMAX]);
            errors++;
        end
    end
endtask

// Layer-by-layer comparison against the golden model. `which` picks the
// tensor; the golden model instance must be named `golden`.
//   1 = conv1 (ACT_A)   2 = pool1 (ACT_B)   3 = conv2 (ACT_A)   4 = pool2 (ACT_B)
task automatic check_layer(input int which, output int errors);
    logic [31:0] got;
    int n, shown;
    begin
        errors = 0;
        shown  = 0;
        n = (which == 1) ? A1_ELEMS : (which == 2) ? P1_ELEMS :
            (which == 3) ? A2_ELEMS : P2_ELEMS;
        for (int i = 0; i < n; i++) begin
            dbg_read((which == 1 || which == 3) ? MEM_ACT_A : MEM_ACT_B, i, got);
            if (got[7:0] !== ((which == 1) ? golden.a1[i] :
                              (which == 2) ? golden.p1[i] :
                              (which == 3) ? golden.a2[i] : golden.p2[i])) begin
                if (shown < 5) begin
                    $display("    FAIL layer%0d[%0d]: got %0d, expected %0d", which, i,
                             got[7:0], (which == 1) ? golden.a1[i] :
                                       (which == 2) ? golden.p1[i] :
                                       (which == 3) ? golden.a2[i] : golden.p2[i]);
                    shown++;
                end
                errors++;
            end
        end
    end
endtask
