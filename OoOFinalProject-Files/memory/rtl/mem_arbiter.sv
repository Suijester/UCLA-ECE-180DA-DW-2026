import mem_pkg::*;

// abstract away RAM model
module mem_arbiter (
    input logic clk,
    input logic rst_n,

    // mshr data accesses
    input logic mem_req_valid,
    output logic mem_req_ready,
    input line_addr_t mem_req_line_addr,
    input mshr_id_t mem_req_mshr_id,

    output logic mem_resp_valid,
    output line_data_t mem_resp_data,
    output mshr_id_t mem_resp_mshr_id,

    // writeback data writes
    output logic arb_write_ready,
    input logic arb_write_valid,
    input line_pkd_t arb_write_line,
    output logic arb_write_done,

    // modport interface
    data_memory_if.client ram
);

endmodule
