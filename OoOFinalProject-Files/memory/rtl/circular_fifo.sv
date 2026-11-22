//fwft circular fifo
module circular_fifo #(
    parameter type T = logic [31:0],
    parameter DEPTH = 8
)(
    input logic clk,
    input logic rst_n,

    input logic write_val,
    input T write_data,
    output logic write_ready,

    output logic read_val,
    output T read_data,
    input logic read_ready
);

T fifo [0:DEPTH-1];

logic [$clog2(DEPTH):0] wr_ptr, rd_ptr;
logic full, empty;

assign empty = wr_ptr == rd_ptr;
assign full = wr_ptr[$clog2(DEPTH)] != rd_ptr[$clog2(DEPTH)] && wr_ptr[$clog2(DEPTH)-1:0] == rd_ptr[$clog2(DEPTH)-1:0];

//supports simultaneous r/w
assign write_ready = !full || (read_val && read_ready);
assign read_val = !empty;
assign read_data = !empty ? fifo[rd_ptr[$clog2(DEPTH)-1:0]] : 'b0;

always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wr_ptr <= 'b0;
        rd_ptr <= 'b0;
    end else begin
        if (write_val && write_ready) begin
            fifo[wr_ptr[$clog2(DEPTH)-1:0]] <= write_data;
            wr_ptr <= wr_ptr + 1'b1; // relies on power of 2 depth
        end
        if (read_ready && !empty) begin
            rd_ptr <= rd_ptr + 1'b1;
        end
    end
end
endmodule