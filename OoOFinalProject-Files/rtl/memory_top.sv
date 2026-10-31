// ===========================================================================
// memory_top.sv -- MEMORY TEAM'S TOP MODULE
//
// Owns: the load/store unit and everything between the backend and the
// external data RAM.
//
//   backend_memory_if.memory   take one ready, non-speculative ROB-head
//                              memory op at a time; return its result
//   data_memory_if.client      master the word-wide data memory bus
//
// The RAM itself is EXTERNAL -- the testbench (or the SoC) provides the
// server side of data_memory_if. Your job is the LSU: address generation,
// byte lanes, sign extension, ordering and backpressure.
// ===========================================================================
module memory_top
    import rv32_ooo_pkg::*;
(
    input  logic clk_i,
    input  logic rst_ni,

    backend_memory_if.memory  be,
    data_memory_if.client     dmem,

    // ----- observability ---------------------------------------------------
    output logic [31:0] dbg_load_count_o,
    output logic [31:0] dbg_store_count_o,
    output logic        dbg_outstanding_o   // a bus transaction is in flight
);

    // =======================================================================
    // TODO -- MEMORY TEAM
    //
    //  1. ACCEPT ONE OP. be.issue_valid / be.issue_ready is a standard
    //     valid/ready handshake: the transfer happens on a rising edge where
    //     both are high. The backend holds issue_uop, source_1 and source_2
    //     steady until you accept. Drive be.busy while you cannot take
    //     another.
    //
    //  2. ADDRESS. address = source_1 + decoded.immediate. source_2 is the
    //     store data.
    //
    //  3. DRIVE THE BUS. dmem is byte-addressed and four-byte aligned, with
    //     little-endian byte lanes:
    //
    //       MEM_WORD  byte_enable = 4'b1111
    //       MEM_HALF  4'b0011 or 4'b1100   depending on address[1]
    //       MEM_BYTE  one bit              selected by address[1:0]
    //
    //     For a store, place the data in the right lanes -- the RAM does not
    //     shift it for you. For a load, extract and then sign- or
    //     zero-extend per decoded.load_unsigned.
    //
    //     Hold request_valid and the whole payload until request_ready
    //     accepts. EVERY accepted request gets exactly one response,
    //     INCLUDING STORES. If you ignore store responses you will leak
    //     credit and eventually deadlock.
    //
    //  4. RETURN THE RESULT on be.result_valid / be.result_ready as an
    //     execution_result_t. A load sets writeback_valid with the extended
    //     data; a store completes with writeback_valid low. Both must carry
    //     the right rob_tag -- generation included.
    //
    //  5. ERRORS. dmem.error marks a failed access. Decide with the backend
    //     how that surfaces and document it.
    //
    //  6. BACKPRESSURE. The RAM model in the testbench will stall you, both
    //     on request_ready and by delaying response_valid. Your LSU must
    //     tolerate arbitrary stalls on either side without losing or
    //     duplicating a transaction. common/elastic_buffer.sv from the repo
    //     is there if you want it.
    // =======================================================================

    // -----------------------------------------------------------------------
    // Placeholder. Delete all of this.
    // -----------------------------------------------------------------------
    logic [31:0] load_count_q, store_count_q;

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            load_count_q  <= '0;
            store_count_q <= '0;
        end else if (be.issue_valid && be.issue_ready) begin
            if (be.issue_uop.decoded.mem_cmd == MEM_LOAD)
                load_count_q <= load_count_q + 32'd1;
            if (be.issue_uop.decoded.mem_cmd == MEM_STORE)
                store_count_q <= store_count_q + 32'd1;
        end
    end

    assign be.issue_ready  = 1'b0;      // TODO: accept work
    assign be.busy         = 1'b0;
    assign be.result_valid = 1'b0;
    assign be.result       = '0;

    assign dmem.request_valid  = 1'b0;
    assign dmem.write          = 1'b0;
    assign dmem.address        = '0;
    assign dmem.write_data     = '0;
    assign dmem.byte_enable    = '0;
    assign dmem.response_ready = 1'b1;

    assign dbg_load_count_o  = load_count_q;
    assign dbg_store_count_o = store_count_q;
    assign dbg_outstanding_o = 1'b0;

endmodule
