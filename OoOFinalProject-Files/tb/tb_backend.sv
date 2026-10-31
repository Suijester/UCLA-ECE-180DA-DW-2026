// ===========================================================================
// tb_backend.sv -- BACKEND TEAM'S TESTBENCH
//
//   ./build.sh backend
//
// The backend sits between three things it does not own, all stubbed here:
//   * a STUB FRONTEND that dispatches a stream of simple ALU uops
//   * a STUB LSU that accepts memory ops and answers after a few cycles
//   * a STUB ACCELERATOR that implements the csr_accelerator_if handshake
//
// The accelerator stub is the interesting one: it is the contract you have to
// get right, and it is checked here before you ever integrate with the real
// accelerator.
// ===========================================================================
module tb_backend;

    import rv32_ooo_pkg::*;
    import accelerator_pkg::*;

    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    frontend_backend_if fb_if   (.clk_i(clk), .rst_ni(rst_n));
    backend_memory_if   bm_if   ();
    csr_accelerator_if  acc_csr ();

    logic [31:0] issue_count;
    logic        acc_busy;

    backend_top dut (
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .fb                (fb_if),
        .mem               (bm_if),
        .acc_csr           (acc_csr),
        .dbg_issue_count_o (issue_count),
        .dbg_acc_busy_o    (acc_busy)
    );

    // -----------------------------------------------------------------------
    // STUB FRONTEND. Offers `offer_count` uops per cycle and re-offers
    // whatever the backend did not accept, so a backend that mishandles the
    // prefix rule loses instructions and the count goes wrong.
    // -----------------------------------------------------------------------
    logic [1:0]  offer_count = 2'd2;
    int unsigned offered_q, accepted_q;
    rob_tag_t    next_tag_q;

    always_comb begin
        fb_if.dispatch_count = offer_count;
        fb_if.dispatch_bundle = '0;
        fb_if.dispatch_bundle.lane0.rob_tag                 = next_tag_q;
        fb_if.dispatch_bundle.lane0.decoded.uop_class       = UOP_ALU;
        fb_if.dispatch_bundle.lane0.decoded.alu_op          = ALU_ADD;
        fb_if.dispatch_bundle.lane0.decoded.operand_a_sel   = OPA_RS1;
        fb_if.dispatch_bundle.lane0.decoded.operand_b_sel   = OPB_IMM;
        fb_if.dispatch_bundle.lane0.decoded.immediate       = 32'd1;
        fb_if.dispatch_bundle.lane0.decoded.writes_rd       = 1'b1;
        fb_if.dispatch_bundle.lane0.has_destination         = 1'b1;
        fb_if.dispatch_bundle.lane1 = fb_if.dispatch_bundle.lane0;
        fb_if.dispatch_bundle.lane1.rob_tag =
            increment_rob_tag(next_tag_q, 2'd1);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            offered_q  <= 0;
            accepted_q <= 0;
            next_tag_q <= '0;
        end else begin
            offered_q  <= offered_q + offer_count;
            accepted_q <= accepted_q + fb_if.dispatch_accept_count;
            next_tag_q <= increment_rob_tag(next_tag_q,
                                            fb_if.dispatch_accept_count);
        end
    end

    assign fb_if.rob_head_tag = '0;
    assign fb_if.retire_valid = 1'b0;
    assign fb_if.retire_tag   = '0;

    // -----------------------------------------------------------------------
    // STUB LSU. Accepts an op, answers three cycles later.
    // -----------------------------------------------------------------------
    int unsigned lsu_timer_q;
    rob_tag_t    lsu_tag_q;
    logic        lsu_busy_q;

    assign bm_if.issue_ready = !lsu_busy_q;
    assign bm_if.busy        = lsu_busy_q;
    assign bm_if.result_valid = lsu_busy_q && (lsu_timer_q == 0);
    assign bm_if.result = '{rob_tag: lsu_tag_q, writeback_valid: 1'b1,
                            writeback_pdst: '0, value: 32'hCAFE_0000,
                            under_unresolved_branch: 1'b0};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lsu_busy_q  <= 1'b0;
            lsu_timer_q <= 0;
        end else if (!lsu_busy_q) begin
            if (bm_if.issue_valid) begin
                lsu_busy_q  <= 1'b1;
                lsu_tag_q   <= bm_if.issue_uop.rob_tag;
                lsu_timer_q <= 3;
            end
        end else if (lsu_timer_q != 0) begin
            lsu_timer_q <= lsu_timer_q - 1;
        end else if (bm_if.result_ready) begin
            lsu_busy_q <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // STUB ACCELERATOR. Implements exactly the contract in accelerator spec
    // section 3.2: takes JOB_CYCLES to run, holds done until activate drops,
    // and errors on a bad length.
    // -----------------------------------------------------------------------
    localparam int unsigned JOB_CYCLES = 50;
    typedef enum logic [1:0] { A_IDLE, A_RUN, A_DONE } astate_e;
    astate_e     astate_q;
    int unsigned atimer_q;
    int unsigned jobs_run = 0;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            astate_q      <= A_IDLE;
            acc_csr.done  <= 1'b0;
            acc_csr.error <= 1'b0;
        end else unique case (astate_q)
            A_IDLE:
                if (acc_csr.activate) begin
                    if (acc_csr.length != 32'd784) begin
                        acc_csr.error <= 1'b1;
                        acc_csr.done  <= 1'b1;
                        astate_q      <= A_DONE;
                    end else begin
                        acc_csr.error <= 1'b0;
                        atimer_q      <= JOB_CYCLES;
                        astate_q      <= A_RUN;
                    end
                end
            A_RUN:
                if (atimer_q == 0) begin
                    acc_csr.done <= 1'b1;
                    jobs_run     <= jobs_run + 1;
                    astate_q     <= A_DONE;
                end else atimer_q <= atimer_q - 1;
            A_DONE:
                if (!acc_csr.activate) begin
                    acc_csr.done  <= 1'b0;
                    acc_csr.error <= 1'b0;
                    astate_q      <= A_IDLE;
                end
            default: astate_q <= A_IDLE;
        endcase
    end

    // -----------------------------------------------------------------------
    int errors = 0;
    int stage  = 0;
    bit halt   = 1'b0;

    task automatic chk(input string name, input logic cond);
        if (!cond) begin
            $display("  FAIL %s", name);
            errors++;
        end
    endtask

    initial begin
        $display("=== backend ===");
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ---- stage 1: reset and interface hygiene --------------------------
        stage = 1;
        chk("dispatch_accept_count is not X",
            !$isunknown(fb_if.dispatch_accept_count));
        chk("dispatch_accept_count <= dispatch_count after reset",
            fb_if.dispatch_accept_count <= fb_if.dispatch_count);
        chk("completion_valid_0 is not X", !$isunknown(fb_if.completion_valid_0));
        chk("completion_valid_1 is not X", !$isunknown(fb_if.completion_valid_1));
        chk("branch_resolve_valid is not X",
            !$isunknown(fb_if.branch_resolve_valid));
        chk("mem.issue_valid is not X", !$isunknown(bm_if.issue_valid));
        chk("mem.result_ready is not X", !$isunknown(bm_if.result_ready));
        chk("acc activate is not X", !$isunknown(acc_csr.activate));
        chk("acc activate low after reset", acc_csr.activate == 1'b0);
        if (errors == 0) $display("  ok   stage 1: reset and interface hygiene");

        // ---- stage 2: does it accept dispatch? -----------------------------
        repeat (50) @(posedge clk);
        #1;
        if (accepted_q == 0) begin
            $display("  --   stage 2 skipped: backend accepted no dispatch in 50 cycles");
            $display("       (expected while backend_top is still a skeleton)");
            halt = 1'b1;
        end
        if (!halt) begin
        stage = 2;
        chk("accept_count never exceeds offer_count", accepted_q <= offered_q);

        // the prefix rule, every cycle
        begin
            int bad = 0;
            repeat (100) begin
                @(posedge clk); #1;
                if (fb_if.dispatch_accept_count > fb_if.dispatch_count) bad++;
            end
            chk("accept_count never exceeds dispatch_count", bad == 0);
        end

        // ---- stage 3: the accelerator CSR handshake ------------------------
        stage = 3;
        if (acc_csr.activate === 1'b0) begin
            $display("  --   stage 3 skipped: the CSR unit never started a job");
            $display("       (the backend must execute csrw 0x7c0 to drive activate)");
        end else begin
            chk("a job completed", jobs_run > 0);
            chk("activate dropped after done", acc_csr.activate == 1'b0);
        end
        end

        $display("");
        if (errors == 0) $display("BACKEND STAGE %0d PASS", stage);
        else             $display("BACKEND FAIL (%0d errors, reached stage %0d)",
                                  errors, stage);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("BACKEND TIMEOUT");
        $fatal(1);
    end

endmodule
