import rv32_ooo_pkg::*;

// address-generation unit
// computes addresses from instructions and source registers, etc.
module address_gen (
    // inputs from backend_memory_if.sv
    input renamed_uop_t issue_uop,
    input logic [XLEN-1:0] source_1,
    input logic [XLEN-1:0] source_2,

    output logic [XLEN-1:0] word_addr,      // word-level address, w/o byte-level access (i.e. word_addr[1:0] == 2'b00)
    output logic [1:0] byte_offset,         // byte-level access
    output logic [3:0] bytes_accessed,      // 0011 accesses first half, 1000 accesses last byte, etc. (identifies size of access, e.g. sh/sw/lh/lw)
    output logic [XLEN-1:0] store_data,     // provides data for store ops
    output logic misaligned_access
);
    logic [XLEN-1:0] immediate;
    assign immediate = issue_uop.decoded.immediate;

    mem_size_e access_size;
    assign access_size = issue_uop.decoded.mem_size;

    logic [XLEN-1:0] byte_addr;
    assign byte_addr = source_1 + immediate;

    assign word_addr = {byte_addr[XLEN-1:2], 2'b00};
    assign byte_offset = byte_addr[1:0];
    assign misaligned_access = (access_size == MEM_HALF && byte_offset[0]) || 
                               (access_size == MEM_WORD && (byte_offset != 2'b00));

    // bytes accessed generation (combines byte offset and access size)
    always_comb begin
        case (access_size)
            MEM_BYTE: bytes_accessed = (4'b0001 << byte_offset);
            MEM_HALF: bytes_accessed = (byte_offset[1]) ? 4'b1100 : 4'b0011;
            MEM_WORD: bytes_accessed = '1;

            default: bytes_accessed = '0;
        endcase
    end

    // store data (concat. data for ease)
    always_comb begin
        case (access_size)
            MEM_BYTE: store_data = {4{source_2[7:0]}};
            MEM_HALF: store_data = {2{source_2[15:0]}};
            MEM_WORD: store_data = source_2;

            default: store_data = '0;
        endcase
    end
endmodule
