// Load result: extract/extend + completion queue
import rv32_ooo_pkg::*;
import mem_pkg::*;

module load_result (
    input clk,
    input rst_n,


    //from load queue
    input logic [XLEN-1:0] lq_out, 
    input logic load_out_valid,
    output logic load_out_ready,
    input rob_tag_t load_out_rob_tag,
    input mem_size_e load_out_mem_size,
    input logic [1:0] load_out_byte_offset,
    input logic load_out_unsigned,
    input logic load_out_under_unresolved_branch,
    input phys_reg_t load_out_writeback_pdst,

    //from store_queue
    input logic store_out_valid,
    output logic store_out_ready,
    input rob_tag_t store_out_rob_tag,
    input logic store_out_comp_under_branch,
    

    //to writeback/rob
    output logic result_valid,
    input logic result_ready,
    output execution_result_t result
);



logic [XLEN-1:0] shifted_data, load_data;
assign shifted_data = lq_out >> (load_out_byte_offset * 8);

execution_result_t load_result, store_result;

//figure out load_data value
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


always_comb begin: create_execution_result_t
    load_result.rob_tag = load_out_rob_tag;
    load_result.writeback_valid = 1'b1;
    load_result.writeback_pdst = load_out_writeback_pdst;
    load_result.value = load_data;
    load_result.under_unresolved_branch = load_out_under_unresolved_branch;

    store_result.rob_tag = store_out_rob_tag;
    store_result.writeback_valid = 'b0;
    store_result.writeback_pdst = 'b0;
    store_result.value = 'b0;
    store_result.under_unresolved_branch = store_out_comp_under_branch;
end

logic load_rd_val, store_rd_val;
execution_result_t load_rd, store_rd;

circular_fifo #(
    .T(execution_result_t),
    .DEPTH(4)
) u_load_complete (
    .clk(clk),
    .rst_n(rst_n),

    .write_val(load_out_valid),
    .write_data(load_result),
    .write_ready(load_out_ready),

    .read_val(load_rd_val),
    .read_data(load_rd),
    .read_ready(!store_sel && grant_valid && result_ready) //rr_arbiter grant + backend ready
);

circular_fifo #(
    .T(execution_result_t),
    .DEPTH(4)
) u_store_complete (
    .clk(clk),
    .rst_n(rst_n),

    .write_val(store_out_valid),
    .write_data(store_result),
    .write_ready(store_out_ready),

    .read_val(store_rd_val),
    .read_data(store_rd),
    .read_ready(store_sel && grant_valid && result_ready) //rr_arbiter grant + backend ready
);

logic [1:0] reqs;
assign reqs = {store_rd_val, load_rd_val};
logic store_sel, grant_valid;

rr_arbiter # (
    .N(2)
) u_completion_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .reqs(reqs),
    .grant_taken(result_ready && result_valid),

    .grant_index(store_sel),
    .grant_valid(grant_valid)
);

assign result = store_sel ? store_rd : load_rd;
assign result_valid = grant_valid;


endmodule
