// ===========================================================================
// imem_model.sv -- synchronous instruction ROM, testbench side of
// instruction_memory_if.
//
// Matches the contract in the interface exactly:
//   * one-cycle synchronous read, no handshake
//   * an enabled clock edge samples `address` and updates data/error
//   * a DISABLED edge HOLDS the previous output
//   * data[31:0] is the word at `address`, data[63:32] the one at address+4
//   * error[n] marks an invalid, misaligned or out-of-range word in lane n
//
// Load a program with load_hex() or poke individual words with put().
// ===========================================================================
module imem_model #(
    parameter int unsigned WORDS = 4096          // 16 KB
) (
    input logic clk_i,
    instruction_memory_if.memory bus
);

    import rv32_ooo_pkg::*;

    logic [31:0] rom [WORDS];

    task automatic clear();
        for (int i = 0; i < WORDS; i++) rom[i] = 32'h0000_0013;   // NOP (addi x0,x0,0)
    endtask

    task automatic load_hex(input string path);
        begin
            clear();
            $readmemh(path, rom);
        end
    endtask

    task automatic put(input int word_index, input logic [31:0] instr);
        rom[word_index] = instr;
    endtask

    initial clear();

    // ----- the synchronous read ---------------------------------------------
    logic [31:0] base_word;
    logic        misaligned, oob_lo, oob_hi;

    assign base_word  = bus.address >> 2;
    assign misaligned = (bus.address[1:0] != 2'b00);
    assign oob_lo     = (base_word >= WORDS);
    assign oob_hi     = ((base_word + 1) >= WORDS);

    always_ff @(posedge clk_i) begin
        if (bus.read_enable) begin
            bus.data[31:0]  <= oob_lo ? 32'h0 : rom[base_word];
            bus.data[63:32] <= oob_hi ? 32'h0 : rom[base_word + 1];
            bus.error       <= {misaligned | oob_hi, misaligned | oob_lo};
        end
        // read_enable low: hold, per the interface contract
    end

endmodule
