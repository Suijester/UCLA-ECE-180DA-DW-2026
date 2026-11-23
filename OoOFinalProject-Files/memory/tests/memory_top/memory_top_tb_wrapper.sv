import rv32_ooo_pkg::*;

module memory_top_tb_wrapper (
    input logic clk,
    input logic rst_n,
    input logic disp_valid,
    input logic [1:0] disp_mem_cmd,
    input logic [1:0] disp_mem_size,
    input logic [ROB_TAG_W-1:0] disp_tag,
    input logic [5:0] disp_pdst,
    output logic disp_ready,
    input logic disp_under_branch,
    input logic issue_valid,
    input logic [1:0] issue_mem_cmd,
    input logic [1:0] issue_mem_size,
    input logic [ROB_TAG_W-1:0] issue_tag,
    input logic [XLEN-1:0] source_1,
    input logic [XLEN-1:0] source_2,
    input logic [XLEN-1:0] issue_immediate,
    input logic result_ready,
    output logic issue_ready,
    output logic busy,
    output logic result_valid,
    output logic [ROB_TAG_W-1:0] result_tag,
    output logic [XLEN-1:0] result_value,
    input logic retire_valid,
    input logic [ROB_TAG_W-1:0] retire_tag,
    input logic [ROB_TAG_W-1:0] rob_head_tag,
    input logic branch_resolve_valid,
    input logic branch_mispredict,
    input logic ram_request_ready,
    input logic ram_response_valid,
    input logic [31:0] ram_read_data,
    output logic ram_request_valid,
    output logic ram_request_write,
    output logic [31:0] ram_request_address,
    output logic ram_response_ready
);
    backend_memory_if backend_if();
    data_memory_if dmem_if();
    frontend_backend_if fe_be_if(.clk_i(clk), .rst_ni(rst_n));

    renamed_uop_t disp_inst;
    renamed_uop_t issue_inst;

    always_comb begin
        disp_inst = '0;
        disp_inst.decoded.mem_cmd = mem_cmd_e'(disp_mem_cmd);
        disp_inst.decoded.mem_size = mem_size_e'(disp_mem_size);
        disp_inst.rob_tag = rob_tag_t'(disp_tag);
        disp_inst.pdst = phys_reg_t'(disp_pdst);
        disp_inst.has_destination = disp_mem_cmd == MEM_LOAD;
        disp_inst.under_unresolved_branch = disp_under_branch;

        issue_inst = '0;
        issue_inst.decoded.mem_cmd = mem_cmd_e'(issue_mem_cmd);
        issue_inst.decoded.mem_size = mem_size_e'(issue_mem_size);
        issue_inst.decoded.immediate = issue_immediate;
        issue_inst.rob_tag = rob_tag_t'(issue_tag);
    end

    assign backend_if.issue_valid = issue_valid;
    assign backend_if.issue_uop = issue_inst;
    assign backend_if.source_1 = source_1;
    assign backend_if.source_2 = source_2;
    assign backend_if.result_ready = result_ready;
    assign backend_if.rob_head_tag = rob_tag_t'(rob_head_tag);
    assign issue_ready = backend_if.issue_ready;
    assign busy = backend_if.busy;
    assign result_valid = backend_if.result_valid;
    assign result_tag = backend_if.result.rob_tag;
    assign result_value = backend_if.result.value;

    assign fe_be_if.retire_valid = retire_valid;
    assign fe_be_if.retire_tag = rob_tag_t'(retire_tag);
    assign fe_be_if.branch_resolve_valid = branch_resolve_valid;
    assign fe_be_if.branch_mispredict = branch_mispredict;
    assign fe_be_if.rob_head_tag = rob_tag_t'(rob_head_tag);

    assign dmem_if.request_ready = ram_request_ready;
    assign dmem_if.response_valid = ram_response_valid;
    assign dmem_if.read_data = ram_read_data;
    assign dmem_if.error = 1'b0;
    assign ram_request_valid = dmem_if.request_valid;
    assign ram_request_write = dmem_if.write;
    assign ram_request_address = dmem_if.address;
    assign ram_response_ready = dmem_if.response_ready;

    memory_top dut (
        .clk(clk), .rst_n(rst_n),
        .backend_if(backend_if),
        .dmem_if(dmem_if),
        .fe_be_if(fe_be_if),
        .disp_valid(disp_valid),
        .disp_inst(disp_inst),
        .disp_ready(disp_ready)
    );
endmodule
