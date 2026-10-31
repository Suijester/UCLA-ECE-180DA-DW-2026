// ===========================================================================
// cnn_ext_mem.sv -- the accelerator's EXTERNAL image, weight and parameter
// memories. Testbench component: the accelerator reads these, never writes
// them.
//
// Loading a test vector is one call:
//
//     cnn_ext_mem xmem (.clk_i(clk), .bus(acc_xmem));
//     ...
//     xmem.load("vectors/v0_box");    // weights + parameters + image
//
// REGISTERED_READ = 0 (default) models an asynchronous SRAM: address out,
// data back the same cycle. That is the contract in cnn_mem_if.sv.
//
// REGISTERED_READ = 1 models a synchronous SRAM: the data arrives one cycle
// after the address. A design built against the default will fail with this
// set -- which is the point. Flipping it is a good late-project exercise in
// pipelining, and it is what a real external memory would do.
// ===========================================================================
module cnn_ext_mem #(
    parameter bit REGISTERED_READ = 1'b0
) (
    input logic      clk_i,
    cnn_mem_if.memory bus
);

    import accelerator_cnn_pkg::*;

    logic [7:0]  img [IMG_MEM_BYTES];
    logic [7:0]  wgt [WGT_MEM_BYTES];
    logic [31:0] par [PARAM_WORDS];

    // -----------------------------------------------------------------------
    // Load one vector directory. This is the "copy the data and the weights
    // in" step -- here it is a plain $readmemh, because these memories live
    // in the testbench.
    // -----------------------------------------------------------------------
    task automatic load(input string dir);
        begin
            clear();
            $readmemh({dir, "/img_mem.hex"},   img);
            $readmemh({dir, "/wgt_mem.hex"},   wgt);
            $readmemh({dir, "/param_mem.hex"}, par);
            if (par[PAR_MAGIC] !== MAGIC)
                $display("  WARNING %s/param_mem.hex magic is %08h, expected %08h",
                         dir, par[PAR_MAGIC], MAGIC);
        end
    endtask

    task automatic clear();
        begin
            for (int i = 0; i < IMG_MEM_BYTES; i++) img[i] = '0;
            for (int i = 0; i < WGT_MEM_BYTES; i++) wgt[i] = '0;
            for (int i = 0; i < PARAM_WORDS;   i++) par[i] = '0;
        end
    endtask

    // -----------------------------------------------------------------------
    // Read ports
    // -----------------------------------------------------------------------
    generate
        if (REGISTERED_READ) begin : g_sync
            always_ff @(posedge clk_i) begin
                bus.img_rdata <= img[bus.img_addr];
                bus.wgt_rdata <= wgt[bus.wgt_addr];
                bus.par_rdata <= par[bus.par_addr];
            end
        end else begin : g_async
            assign bus.img_rdata = img[bus.img_addr];
            assign bus.wgt_rdata = wgt[bus.wgt_addr];
            assign bus.par_rdata = par[bus.par_addr];
        end
    endgenerate

endmodule
