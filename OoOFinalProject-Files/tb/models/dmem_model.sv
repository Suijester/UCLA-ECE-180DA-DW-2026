// ===========================================================================
// dmem_model.sv -- data RAM, the server side of data_memory_if.
//
// Deliberately HOSTILE, because a memory that always answers in one cycle
// hides exactly the bugs this interface exists to expose. Two knobs:
//
//   STALL_PCT     roughly what percentage of cycles request_ready is low
//   MAX_LATENCY   each response is delayed 0..MAX_LATENCY extra cycles
//
// Set both to 0 for a frictionless memory while you bring your LSU up, then
// turn them on. An LSU that works at (0, 0) and breaks at (40, 5) has a real
// bug, not a testbench problem.
//
// The model honours the interface contract:
//   * exactly one response per accepted request, INCLUDING STORES
//   * responses come back in order
//   * the request payload is sampled only on request_valid && request_ready
//   * byte_enable selects which lanes a store writes
// ===========================================================================
module dmem_model #(
    parameter int unsigned WORDS       = 8192,   // 32 KB
    parameter int unsigned STALL_PCT   = 0,
    parameter int unsigned MAX_LATENCY = 0,
    parameter int unsigned SEED        = 32'h1234_5678
) (
    input logic clk_i,
    input logic rst_ni,
    data_memory_if.server bus
);

    logic [31:0] ram [WORDS];

    // ----- loading / inspection --------------------------------------------
    task automatic clear();
        for (int i = 0; i < WORDS; i++) ram[i] = '0;
    endtask

    task automatic load_hex(input string path);
        begin
            clear();
            $readmemh(path, ram);
        end
    endtask

    function automatic logic [31:0] peek(input int word_index);
        peek = ram[word_index];
    endfunction

    task automatic poke(input int word_index, input logic [31:0] value);
        ram[word_index] = value;
    endtask

    initial clear();

    // ----- pseudo-random stall / latency -----------------------------------
    logic [31:0] rng_q;
    always_ff @(posedge clk_i) begin
        if (!rst_ni) rng_q <= SEED;
        else         rng_q <= rng_q * 32'd1103515245 + 32'd12345;
    end

    // ----- in-flight response queue ----------------------------------------
    localparam int unsigned QD = 8;

    logic [31:0] q_data  [QD];
    logic        q_err   [QD];
    int unsigned q_delay [QD];
    int unsigned head_q, tail_q, count_q;

    logic accept, present, pop, push;

    // A slot is available unless the queue is full.
    always_comb begin
        if (!rst_ni)                bus.request_ready = 1'b0;
        else if (count_q >= QD - 1) bus.request_ready = 1'b0;
        else if (STALL_PCT == 0)    bus.request_ready = 1'b1;
        else bus.request_ready = (((rng_q >> 16) % 100) >= STALL_PCT);
    end

    assign accept  = bus.request_valid && bus.request_ready;
    assign present = (count_q != 0) && (q_delay[head_q] == 0);
    assign pop     = present && bus.response_ready;
    assign push    = accept;

    assign bus.response_valid = present;
    assign bus.read_data      = q_data[head_q];
    assign bus.error          = present && q_err[head_q];

    logic [31:0] windex;
    logic        oob;
    assign windex = bus.address >> 2;
    assign oob    = (windex >= WORDS);

    always_ff @(posedge clk_i) begin
        if (!rst_ni) begin
            head_q  <= 0;
            tail_q  <= 0;
            count_q <= 0;
            for (int i = 0; i < QD; i++) begin
                q_data[i]  <= '0;
                q_err[i]   <= 1'b0;
                q_delay[i] <= 0;
            end
        end else begin

            // age the head
            if ((count_q != 0) && (q_delay[head_q] != 0))
                q_delay[head_q] <= q_delay[head_q] - 1;

            // enqueue; a store commits to the RAM on the same edge
            if (push) begin
                if (bus.write && !oob) begin
                    if (bus.byte_enable[0]) ram[windex][ 7: 0] <= bus.write_data[ 7: 0];
                    if (bus.byte_enable[1]) ram[windex][15: 8] <= bus.write_data[15: 8];
                    if (bus.byte_enable[2]) ram[windex][23:16] <= bus.write_data[23:16];
                    if (bus.byte_enable[3]) ram[windex][31:24] <= bus.write_data[31:24];
                end
                q_data [tail_q] <= oob ? 32'h0 : ram[windex];
                q_err  [tail_q] <= oob;
                q_delay[tail_q] <= (MAX_LATENCY == 0) ? 0
                                  : (((rng_q >> 8) % (MAX_LATENCY + 1)));
                tail_q <= (tail_q + 1) % QD;
            end

            if (pop) head_q <= (head_q + 1) % QD;

            count_q <= count_q + (push ? 1 : 0) - (pop ? 1 : 0);
        end
    end

endmodule
