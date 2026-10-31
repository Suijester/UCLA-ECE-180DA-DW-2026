// ===========================================================================
// tb_memory.sv -- MEMORY TEAM'S TESTBENCH
//
//   ./build.sh memory
//
// Drives the LSU from a stub backend and hangs a real RAM model off the
// other side. The RAM is deliberately hostile: it stalls request_ready and
// delays responses. An LSU that only works against a zero-latency memory
// will pass stage 2 and fail stage 3, which is the point.
// ===========================================================================
module tb_memory;

    import rv32_ooo_pkg::*;

    logic clk = 0;
    logic rst_n;
    always #5 clk = ~clk;

    backend_memory_if be_if   ();
    data_memory_if    dmem_if ();

    logic [31:0] load_count, store_count;
    logic        outstanding;

`ifdef USE_REF
    memory_ref dut (
`else
    memory_top dut (
`endif
        .clk_i             (clk),
        .rst_ni            (rst_n),
        .be                (be_if),
        .dmem              (dmem_if),
        .dbg_load_count_o  (load_count),
        .dbg_store_count_o (store_count),
        .dbg_outstanding_o (outstanding)
    );

    // Hostile by default. Set STALL_PCT/MAX_LATENCY to 0 while bringing up.
    dmem_model #(.WORDS(4096), .STALL_PCT(35), .MAX_LATENCY(4)) ram (
        .clk_i  (clk),
        .rst_ni (rst_n),
        .bus    (dmem_if)
    );

    // -----------------------------------------------------------------------
    // Stub backend: issue one memory op and wait for its result.
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

    task automatic be_idle();
        begin
            be_if.issue_valid  = 1'b0;
            be_if.issue_uop    = '0;
            be_if.source_1     = '0;
            be_if.source_2     = '0;
            be_if.rob_head_tag = '0;
            be_if.result_ready = 1'b1;
        end
    endtask

    // Issue one load or store; wait for the result. `ok` is 0 on timeout.
    task automatic mem_op(input mem_cmd_e cmd, input mem_size_e size,
                          input logic uns, input logic [31:0] base,
                          input logic [31:0] offset, input logic [31:0] sdata,
                          output logic [31:0] rdata, output logic ok);
        int guard;
        renamed_uop_t u;
        begin
            u = '0;
            u.decoded.uop_class     = (cmd == MEM_LOAD) ? UOP_LOAD : UOP_STORE;
            u.decoded.mem_cmd       = cmd;
            u.decoded.mem_size      = size;
            u.decoded.load_unsigned = uns;
            u.decoded.immediate     = offset;
            u.rob_tag               = '0;
            u.has_destination       = (cmd == MEM_LOAD);

            @(negedge clk);
            be_if.issue_valid = 1'b1;
            be_if.issue_uop   = u;
            be_if.source_1    = base;
            be_if.source_2    = sdata;

            guard = 0;
            while (!(be_if.issue_valid && be_if.issue_ready) && guard < 2000) begin
                @(posedge clk); guard++;
            end
            @(negedge clk);
            be_if.issue_valid = 1'b0;

            guard = 0;
            while (!be_if.result_valid && guard < 2000) begin
                @(posedge clk); guard++;
            end
            ok    = (guard < 2000);
            rdata = be_if.result.value;
            @(negedge clk);
        end
    endtask

    initial begin
        logic [31:0] d;
        logic ok;

        $display("=== memory ===");
        be_idle();
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        @(posedge clk); #1;

        // ---- stage 1: reset and interface hygiene --------------------------
        stage = 1;
        chk("issue_ready is not X", !$isunknown(be_if.issue_ready));
        chk("busy is not X", !$isunknown(be_if.busy));
        chk("result_valid is not X", !$isunknown(be_if.result_valid));
        chk("result_valid low after reset", be_if.result_valid == 1'b0);
        chk("dmem.request_valid is not X", !$isunknown(dmem_if.request_valid));
        chk("dmem.request_valid low after reset", dmem_if.request_valid == 1'b0);
        chk("dmem.response_ready is not X", !$isunknown(dmem_if.response_ready));
        if (errors == 0) $display("  ok   stage 1: reset and interface hygiene");

        // ---- stage 2: does it accept work? ---------------------------------
        // Watch a window rather than sampling once: issue_ready may only be
        // high while the LSU is idle, which is intermittent once it is
        // actually working. Probe with issue_valid LOW first -- a well-built
        // LSU asserts ready when it has room, without waiting to see valid.
        begin
            bit seen_ready = 1'b0;
            repeat (30) begin
                @(posedge clk); #1;
                if (be_if.issue_ready) seen_ready = 1'b1;
            end
            if (!seen_ready) begin
                @(negedge clk); be_if.issue_valid = 1'b1;
                repeat (30) begin
                    @(posedge clk); #1;
                    if (be_if.issue_ready) seen_ready = 1'b1;
                end
                @(negedge clk); be_if.issue_valid = 1'b0;
                if (seen_ready)
                    $display("  note  issue_ready only asserts once issue_valid is high; prefer making ready independent of valid");
            end
            if (!seen_ready) begin
                $display("  --   stage 2 skipped: issue_ready never asserted");
                $display("       (expected while memory_top is still a skeleton)");
                halt = 1'b1;
            end
        end
        if (!halt) begin
        stage = 2;

        // ---- stage 3: word store then load ---------------------------------
        ram.clear();
        mem_op(MEM_STORE, MEM_WORD, 1'b0, 32'h100, 32'd0, 32'hDEAD_BEEF, d, ok);
        chk("word store completed", ok);
        chk("word landed in RAM", ram.peek(32'h100 >> 2) == 32'hDEAD_BEEF);

        mem_op(MEM_LOAD, MEM_WORD, 1'b0, 32'h100, 32'd0, 32'd0, d, ok);
        chk("word load completed", ok);
        chk("word load returned the stored value", d == 32'hDEAD_BEEF);

        // ---- byte lanes ----------------------------------------------------
        ram.poke(32'h200 >> 2, 32'h8070_6050);
        mem_op(MEM_LOAD, MEM_BYTE, 1'b1, 32'h200, 32'd0, 32'd0, d, ok);
        chk("byte load, lane 0, unsigned", ok && (d == 32'h0000_0050));
        mem_op(MEM_LOAD, MEM_BYTE, 1'b1, 32'h200, 32'd3, 32'd0, d, ok);
        chk("byte load, lane 3, unsigned", ok && (d == 32'h0000_0080));
        mem_op(MEM_LOAD, MEM_BYTE, 1'b0, 32'h200, 32'd3, 32'd0, d, ok);
        chk("byte load, lane 3, SIGN EXTENDED", ok && (d == 32'hFFFF_FF80));
        mem_op(MEM_LOAD, MEM_HALF, 1'b1, 32'h200, 32'd2, 32'd0, d, ok);
        chk("halfword load, upper, unsigned", ok && (d == 32'h0000_8070));
        mem_op(MEM_LOAD, MEM_HALF, 1'b0, 32'h200, 32'd2, 32'd0, d, ok);
        chk("halfword load, upper, SIGN EXTENDED", ok && (d == 32'hFFFF_8070));

        // byte store must not disturb its neighbours
        ram.poke(32'h300 >> 2, 32'hAAAA_AAAA);
        mem_op(MEM_STORE, MEM_BYTE, 1'b0, 32'h300, 32'd1, 32'h0000_0055, d, ok);
        chk("byte store touched only its lane",
            ok && (ram.peek(32'h300 >> 2) == 32'hAAAA_55AA));

        // ---- stage 4: a long run under backpressure ------------------------
        stage = 4;
        begin
            int bad = 0;
            for (int i = 0; i < 64; i++) begin
                mem_op(MEM_STORE, MEM_WORD, 1'b0, 32'h400 + (i*4), 32'd0,
                       32'h1000_0000 + i, d, ok);
                if (!ok) bad++;
            end
            for (int i = 0; i < 64; i++) begin
                mem_op(MEM_LOAD, MEM_WORD, 1'b0, 32'h400 + (i*4), 32'd0,
                       32'd0, d, ok);
                if (!ok || d !== (32'h1000_0000 + i)) bad++;
            end
            chk("64 stores and 64 loads survive stalls and latency", bad == 0);
        end
        end

        $display("");
        if (errors == 0) $display("MEMORY STAGE %0d PASS", stage);
        else             $display("MEMORY FAIL (%0d errors, reached stage %0d)",
                                  errors, stage);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("MEMORY TIMEOUT");
        $fatal(1);
    end

endmodule
