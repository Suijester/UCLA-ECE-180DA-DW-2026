
module addr_gen_tb_wrapper
    import rv32_ooo_pkg::*;
(
    input logic [XLEN-1:0] immediate,
    input mem_size_e access_size,
    input logic [XLEN-1:0] source_1,
    input logic [XLEN-1:0] source_2,

    output logic [XLEN-1:0] word_addr,
    output logic [1:0] byte_offset,
    output logic [3:0] bytes_accessed,
    output logic [XLEN-1:0] store_data,
    output logic misaligned_access
);

    renamed_uop_t issue_uop;

    always_comb begin
        issue_uop = '0;
        issue_uop.decoded.immediate = immediate;
        issue_uop.decoded.mem_size = access_size;
    end

    address_gen dut (
        .issue_uop(issue_uop),
        .source_1(source_1),
        .source_2(source_2),
        .word_addr(word_addr),
        .byte_offset(byte_offset),
        .bytes_accessed(bytes_accessed),
        .store_data(store_data),
        .misaligned_access(misaligned_access)
    );

endmodule
