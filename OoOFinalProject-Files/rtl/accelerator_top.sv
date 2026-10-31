// ===========================================================================
// accelerator_top.sv -- ACCELERATOR TEAM'S TOP MODULE
//
// The MNIST CNN accelerator. See doc/ACCELERATOR-SPEC.md for the full
// specification; this header is the boundary and the build order.
//
//   csr_accelerator_if.accelerator   start/done/error from the backend's CSRs
//   cnn_mem_if.accelerator           read the image, weights and parameters
//                                    from EXTERNAL memory
//   acc_debug_if.target              let the testbench read your result and
//                                    your intermediate activations
//
// WHAT IS OUTSIDE YOU
//   The image, the weights and the per-layer parameters live in external
//   memories that the testbench owns and preloads. You only read them, one
//   byte (or one parameter word) per cycle per port, combinationally.
//
// WHAT IS INSIDE YOU
//   The two activation scratchpads (ACT_A, ACT_B) and the result memory.
//   They are instantiated below -- that plumbing is given, because it is not
//   the learning objective.
//
// BUILD IT IN THIS ORDER, checking each layer against the golden model
// before starting the next. Do not write all four layers and then debug.
//
//     1. conv1            -> compare ACT_A against golden.a1[]
//     2. + maxpool 1      -> compare ACT_B against golden.p1[]
//     3. + conv2          -> compare ACT_A against golden.a2[]
//     4. + maxpool 2      -> compare ACT_B against golden.p2[]
//     5. + fc and argmax  -> ./build.sh accel   (full ACCEL PASS)
// ===========================================================================
module accelerator_top
    import accelerator_cnn_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    csr_accelerator_if.accelerator csr,
    cnn_mem_if.accelerator         xmem,
    acc_debug_if.target            dbg,

    // ----- observability ---------------------------------------------------
    output logic        dbg_busy_o,
    output logic [31:0] dbg_cycles_o      // cycles taken by the last job
);

    // =======================================================================
    // GIVEN: internal scratchpads and the debug readback mux.
    // You should not need to change this unless you bank the activation
    // memories for more parallelism (spec section 7.3).
    // =======================================================================
    logic [ACT_A_ADDR_W-1:0] aa_ra, aa_wa;
    logic [7:0]              aa_rd, aa_wd;
    logic                    aa_we;
    logic [ACT_B_ADDR_W-1:0] ab_ra, ab_wa;
    logic [7:0]              ab_rd, ab_wd;
    logic                    ab_we;
    logic [RES_ADDR_W-1:0]   res_wa;
    logic [31:0]             res_wd, res_rd;
    logic                    res_we;

    logic [7:0] dbg_aa, dbg_ab;

    acc_sram8 #(.DEPTH(ACT_A_BYTES)) u_act_a (
        .clk_i, .we_i(aa_we), .waddr_i(aa_wa), .wdata_i(aa_wd),
        .raddr_a_i(aa_ra), .rdata_a_o(aa_rd),
        .raddr_b_i(dbg.addr[ACT_A_ADDR_W-1:0]), .rdata_b_o(dbg_aa));

    acc_sram8 #(.DEPTH(ACT_B_BYTES)) u_act_b (
        .clk_i, .we_i(ab_we), .waddr_i(ab_wa), .wdata_i(ab_wd),
        .raddr_a_i(ab_ra), .rdata_a_o(ab_rd),
        .raddr_b_i(dbg.addr[ACT_B_ADDR_W-1:0]), .rdata_b_o(dbg_ab));

    acc_sram32 #(.DEPTH(RES_WORDS)) u_res (
        .clk_i, .we_i(res_we), .waddr_i(res_wa), .wdata_i(res_wd),
        .raddr_i(dbg.addr[RES_ADDR_W-1:0]), .rdata_o(res_rd));

    always_comb begin
        unique case (dbg.sel)
            MEM_RES:   dbg.rdata = res_rd;
            MEM_ACT_A: dbg.rdata = {24'd0, dbg_aa};
            MEM_ACT_B: dbg.rdata = {24'd0, dbg_ab};
            default:   dbg.rdata = 32'd0;
        endcase
    end

    // =======================================================================
    // YOUR DESIGN STARTS HERE
    // =======================================================================

    // -----------------------------------------------------------------------
    // TODO 1 -- control FSM and the CSR handshake (spec section 3.2).
    //
    //   idle            : csr.done = 0, csr.error = 0
    //   csr.activate=1  : latch csr.memory_location (byte offset of the image
    //                     in the EXTERNAL image memory) and csr.length (which
    //                     must equal IMG_PIXELS = 784). Start.
    //   finished        : csr.done = 1, and HOLD it.
    //   csr.activate=0  : drop csr.done, return to idle.
    //
    // `done` is a level, not a pulse. The backend's CSR unit samples it.
    //
    // Bad length: set BOTH csr.error and csr.done, wait for activate to
    // drop, then clear both. An invalid job must complete, not hang.
    //
    // Every per-job register -- accumulators, loop counters, the running
    // argmax -- must be re-initialized at the START OF A JOB, not just at
    // reset. Back-to-back jobs are tested.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 2 -- read the parameters out of the external parameter memory.
    //
    //   xmem.par_addr = PAR_SHIFT1   -> shift1
    //                   PAR_SHIFT2   -> shift2
    //                   PAR_CONV1_B + 0..2   conv1 biases  (int32)
    //                   PAR_CONV2_B + 0..2   conv2 biases  (int32)
    //                   PAR_FC_B    + 0..9   fc biases     (int32)
    //
    // Only 16 values. Walk them once at the start of each job and latch
    // them into registers.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 3 -- conv1. 28x28x1, 5x5 kernel, 3 filters, stride 1, valid.
    //
    //   xmem.img_addr = img_base + (oy+ky)*28 + (ox+kx)
    //   xmem.wgt_addr = idx_conv1_w(f, ky, kx)
    //   acc           = conv1_bias[f] + sum of img * wgt
    //   ACT_A[idx_a1(oy,ox,f)] = requant(acc, shift1)
    //
    // The image byte is UNSIGNED (zero-extend). The weight is SIGNED
    // (sign-extend). Getting this wrong is silent and is the most common bug
    // in this design -- spec section 4.3.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 4 -- maxpool 1. 24x24x3 -> 12x12x3, 2x2, stride 2.
    //           Reads ACT_A, writes ACT_B.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 5 -- conv2. 12x12x3, 5x5x3, 3 filters, stride 1, valid.
    //           Reads ACT_B and xmem.wgt_addr = idx_conv2_w(f,ky,kx,c).
    //           Writes ACT_A -- reusing the buffer is safe, conv2 is done
    //           with ACT_B's contents before pool2 runs.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 6 -- maxpool 2. 8x8x3 -> 4x4x3. Reads ACT_A, writes ACT_B.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // TODO 7 -- fully connected and argmax.
    //
    //   for o in 0..9:  logit[o] = fc_bias[o] + sum_i p2[i] * fc_w[o][i]
    //   RES[RES_LOGIT + o] = logit[o]     int32, NO requantization
    //   RES[RES_ARGMAX]    = argmax       lowest index wins a tie
    //   RES[RES_MAGIC]     = MAGIC        write this last
    //
    // The flatten is free: ACT_B already holds pool2 channel-fastest, which
    // is the order the FC weights expect. Read ACT_B[0..47] straight through.
    //
    // common/acc_argmax.sv is provided if you want it.
    // -----------------------------------------------------------------------


    // -----------------------------------------------------------------------
    // Placeholder drivers so the design elaborates and the testbench runs
    // cleanly while you build. Delete all of this.
    // -----------------------------------------------------------------------
    assign aa_we = 1'b0;  assign aa_wa = '0;  assign aa_wd = '0;  assign aa_ra = '0;
    assign ab_we = 1'b0;  assign ab_wa = '0;  assign ab_wd = '0;  assign ab_ra = '0;
    assign res_we = 1'b0; assign res_wa = '0; assign res_wd = '0;

    assign xmem.img_addr = '0;
    assign xmem.wgt_addr = '0;
    assign xmem.par_addr = '0;

    assign dbg_busy_o   = csr.activate && !csr.done;
    assign dbg_cycles_o = '0;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            csr.done  <= 1'b0;
            csr.error <= 1'b0;
        end else begin
            csr.done  <= csr.activate;   // claim completion immediately
            csr.error <= 1'b0;
        end
    end

endmodule
