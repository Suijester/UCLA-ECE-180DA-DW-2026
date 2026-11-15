// flattens store_forward's unpacked-array ports so cocotb can drive them:
// slot i of each array sits at bits [i*W +: W] of the flat vector
module store_forward_tb_wrapper
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
(
    input logic [XLEN-1:0] ld_word_addr,
    input logic [3:0] ld_bytes_accessed,
    input logic [$clog2(SQ_SIZE):0] ld_sq_tail,

    input logic [$clog2(SQ_SIZE):0] sq_head,
    input logic [SQ_SIZE-1:0] sq_valid,
    input logic [SQ_SIZE*XLEN-1:0] sq_word_addr_flat,
    input logic [SQ_SIZE*4-1:0] sq_bytes_accessed_flat,
    input logic [SQ_SIZE*XLEN-1:0] sq_write_data_flat,

    input logic [XLEN-1:0] cache_read_data,

    output logic [XLEN-1:0] fwd_data,
    output logic [3:0] fwd_bytes_from_store,
    output logic fwd_all_from_store
);

    logic [XLEN-1:0] word_addr_arr [SQ_SIZE];
    logic [3:0] bytes_arr [SQ_SIZE];
    logic [XLEN-1:0] data_arr [SQ_SIZE];

    always_comb begin
        for (int i = 0; i < SQ_SIZE; i++) begin
            word_addr_arr[i] = sq_word_addr_flat[i*XLEN +: XLEN];
            bytes_arr[i] = sq_bytes_accessed_flat[i*4 +: 4];
            data_arr[i] = sq_write_data_flat[i*XLEN +: XLEN];
        end
    end

    store_forward dut (
        .ld_word_addr(ld_word_addr),
        .ld_bytes_accessed(ld_bytes_accessed),
        .ld_sq_tail(ld_sq_tail),
        .sq_head(sq_head),
        .sq_valid(sq_valid),
        .sq_word_addr(word_addr_arr),
        .sq_bytes_accessed(bytes_arr),
        .sq_write_data(data_arr),
        .cache_read_data(cache_read_data),
        .fwd_data(fwd_data),
        .fwd_bytes_from_store(fwd_bytes_from_store),
        .fwd_all_from_store(fwd_all_from_store)
    );

endmodule