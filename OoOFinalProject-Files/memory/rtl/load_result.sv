// Load result: extract/extend + completion queue
import rv32_ooo_pkg::*;
import mem_pkg::*;

module load_result(
    //from load queue
    input logic [XLEN-1:0] lq_out, 
    input logic load_out_valid,
    output logic load_out_ready,
    input rob_tag_t load_out_rob_tag,
    input mem_size_e load_out_mem_size,
    input logic [1:0] load_out_byte_offset,
    input logic load_out_unsigned,

    //to writeback/rob
    output logic [XLEN-1:0] load_data,
    output logic load_data_valid,
    input logic load_data_ready,
    output rob_tag_t load_data_rob_tag
);

assign load_out_ready = load_data_ready;
assign load_data_valid = load_out_valid;
assign load_data_rob_tag = load_out_rob_tag;

logic [XLEN-1:0] shifted_data;
assign shifted_data = lq_out >> (load_out_byte_offset * 8);

always_comb begin
    case (load_out_mem_size) 
        MEM_BYTE: begin
            load_data = load_out_unsigned ?  {{(XLEN-8){1'b0}}, shifted_data[7:0]} :  {{(XLEN-8){shifted_data[7]}}, shifted_data[7:0]} ;
        end
        MEM_HALF: begin
            load_data = load_out_unsigned ?  {{(XLEN-16){1'b0}}, shifted_data[15:0]} :  {{(XLEN-16){shifted_data[15]}}, shifted_data[15:0]};
        end
        MEM_WORD: begin
            load_data = shifted_data;
        end
        default: begin
            load_data = 'b0;
        end
    endcase
end
    

endmodule
