// splits store_sets' 2-lane unpacked-array ports into one port per lane so
// cocotb can drive them, and shortens the SSIT clear interval for testing
module store_sets_tb_wrapper
    import rv32_ooo_pkg::*;
    import mem_pkg::*;
#(
    parameter int SSIT_CLEAR_CYCLES = 64
) (
    input logic clk,
    input logic rst_n,

    input logic [1:0] disp_valid,
    input logic [1:0] disp_is_load,
    input logic [1:0] disp_is_store,
    input logic [XLEN-1:0] disp_pc0,
    input logic [XLEN-1:0] disp_pc1,
    input logic [$clog2(SQ_SIZE):0] disp_st_ptr0,
    input logic [$clog2(SQ_SIZE):0] disp_st_ptr1,

    output logic [1:0] disp_wait_valid,
    output logic [$clog2(SQ_SIZE):0] disp_wait_st_ptr0,
    output logic [$clog2(SQ_SIZE):0] disp_wait_st_ptr1,

    input logic st_issue_valid,
    input logic [$clog2(SQ_SIZE):0] st_issue_ptr,

    input logic viol_valid,
    input logic [XLEN-1:0] viol_load_pc,
    input logic [XLEN-1:0] viol_store_pc,

    input logic flush_all,
    input logic [SQ_SIZE-1:0] sq_squash_mask
);

    logic [XLEN-1:0] pc_arr [2];
    st_ptr_t st_ptr_arr [2];
    st_ptr_t wait_arr [2];

    assign pc_arr[0] = disp_pc0;
    assign pc_arr[1] = disp_pc1;
    assign st_ptr_arr[0] = disp_st_ptr0;
    assign st_ptr_arr[1] = disp_st_ptr1;
    assign disp_wait_st_ptr0 = wait_arr[0];
    assign disp_wait_st_ptr1 = wait_arr[1];

    store_sets #(.SSIT_CLEAR_CYCLES(SSIT_CLEAR_CYCLES)) dut (
        .clk(clk), .rst_n(rst_n),
        .disp_valid(disp_valid), .disp_is_load(disp_is_load), .disp_is_store(disp_is_store),
        .disp_pc(pc_arr), .disp_st_ptr(st_ptr_arr),
        .disp_wait_valid(disp_wait_valid), .disp_wait_st_ptr(wait_arr),
        .st_issue_valid(st_issue_valid), .st_issue_ptr(st_issue_ptr),
        .viol_valid(viol_valid), .viol_load_pc(viol_load_pc), .viol_store_pc(viol_store_pc),
        .flush_all(flush_all), .sq_squash_mask(sq_squash_mask)
    );

endmodule