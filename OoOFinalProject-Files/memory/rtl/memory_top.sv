// Memory team top. Port list matches the instructor's rv32_ooo_top.
import rv32_ooo_pkg::*;
import mem_pkg::*;

module memory_top(
    input logic clk,
    input logic rst_n,

    backend_memory_if.memory backend_if,
    data_memory_if.client dmem_if,
);

logic is_load;
logic is_store;

assign is_load = backend_if.issue_uop.decoded.mem_cmd == MEM_LOAD;
assign is_store = backend_if.issue_uop.decoded.mem_cmd == MEM_STORE;

//AGU outputs
logic [XLEN-1:0] agu_word_addr;      
logic [1:0] agu_byte_offset;         
logic [3:0] agu_bytes_accessed;      
logic [XLEN-1:0] agu_store_data;     
logic agu_misaligned_access;

//load queue outputs
logic lq_issue_ready;

//LQ and SQ interface
st_ptr_t sq_tail;
logic sq_check_valid;
logic [XLEN-1:0] sq_check_addr;
logic [3:0] sq_check_byte_mask;
st_ptr_t sq_check_tail;
logic [XLEN-1:0] sq_fwd_data;
logic [3:0] sq_fwd_bytes;
logic sq_fwd_all;
logic sq_stall;

//load_queue and load_result interface:
logic [XLEN-1:0] load_out;
logic load_out_valid;
logic load_out_ready;
rob_tag_t load_out_rob_tag;
mem_size_e load_out_mem_size;
logic [1:0] load_out_byte_offset;
logic load_out_unsigned;

//load_queue and l1 interface
logic lq_l1_req_valid;
logic [XLEN-1:0] lq_l1_req_addr;
logic [3:0]      lq_l1_req_byte_mask;
lq_idx_t lq_l1_req_ld_id;


//l1 outputs
logic req_ready;
logic l1_resp_valid;
logic l1_resp_hit;
lq_idx_t l1_resp_ld_id;
logic [XLEN-1:0] l1_resp_data;
logic resp_is_store;

//load_queue and mshr interface
logic wake_valid;
line_addr_t wake_line_addr;

//TODO: update when SQ instantiated
assign backend_if.issue_ready = is_load && lq_issue_ready;

address_gen u_agu (
    .issue_uop(backend_if.issue_uop),
    .source_1(backend_if.source_1),
    .source_2(backend_if.source_2),

    .word_addr(agu_word_addr),      // word-level address, w/o byte-level access (i.e. word_addr[1:0] == 2'b00)
    .byte_offset(agu_byte_offset),         // byte-level access
    .bytes_accessed(agu_bytes_accessed),      // 0011 accesses first half, 1000 accesses last byte, etc. (identifies size of access, e.g. sh/sw/lh/lw)
    .store_data(agu_store_data),     // provides data for store ops
    .misaligned_access(agu_misaligned_access)
);

load_queue u_load_queue (
    .clk(clk),
    .rst_n(rst_n),

    //from dispatch
    input logic disp_valid, //wr_en
    input renamed_uop_t disp_inst, //currently 1 wide allocation
    output logic disp_ready, 

    //from address_gen, after issue
    .word_addr(agu_word_addr),      // word-level address, w/o byte-level access (i.e. word_addr[1:0] == 2'b00)
    .byte_offset(agu_byte_offset),         // byte-level access
    .bytes_accessed(agu_bytes_accessed),      // 0011 accesses first half, 1000 accesses last byte, etc. (identifies size of access, e.g. sh/sw/lh/lw)
    .misaligned_access(agu_misaligned_access),
    .issue_rob_tag(backend_if.issue_uop.rob_tag),
    .issue_valid(backend_if.issue_valid && is_load),
    .issue_ready(lq_issue_ready),

    //from retire
    //TODO: figure out if frontend_backend_if has retire signals we can use, otherwise ask for an amendment to the if
    .retire_valid(backend_if.retire_valid),
    .retire_rob_tag(backend_if.retire_rob_inst),

    //TODO: connect to store queue
    //from store_queue   
    .sq_tail(sq_tail),

    //to store forward
    .check_valid(sq_check_valid),
    .check_addr(sq_check_addr),
    .check_byte_mask(sq_check_byte_mask),
    .check_sq_tail(sq_check_tail),
 

    //from store_forward
    .fwd_data(sq_fwd_data),
    .fwd_bytes_from_store(sq_fwd_bytes),
    .fwd_all_from_store(sq_fwd_all),
    .sq_stall(sq_stall),

    //forwarded to load_result
    .load_out(load_out), 
    .load_out_valid(load_out_valid),
    .load_out_ready(load_out_ready),
    .load_out_rob_tag(load_out_rob_tag),
    .load_out_mem_size(load_out_mem_size),
    .load_out_byte_offset(load_out_byte_offset),
    .load_out_unsigned(load_out_unsigned),

    //to L1 cache
    .l1_req_valid(lq_l1_req_valid),
    .l1_req_addr(lq_l1_req_addr),
    .l1_req_ready(l1_req_ready && l1_grant_valid && !l1_grant_index),
    .l1_req_byte_mask(lq_l1_req_byte_mask),
    .l1_req_ld_id(lq_l1_req_ld_id),

    //from L1 cache
    .l1_resp_valid(l1_resp_valid),
    .l1_resp_hit(l1_resp_hit),
    .l1_resp_ld_id(l1_resp_ld_id),
    .l1_resp_data(l1_resp_data),

    //mshr wakeup
    .wake_valid(wake_valid),
    .wake_line_addr(wake_line_addr)

);

load_result u_load_result (
    .lq_out(load_out), 
    .load_out_valid(load_out_valid),
    .load_out_ready(load_out_ready),
    .load_out_rob_tag(load_out_rob_tag),
    .load_out_mem_size(load_out_mem_size),
    .load_out_byte_offset(load_out_byte_offset),
    .load_out_unsigned(load_out_unsigned),

    //to writeback/rob
    //TODO: add signals and connect
    output logic [XLEN-1:0] load_data,
    output logic load_data_valid,
    input logic load_data_ready,
    output rob_tag_t load_data_rob_tag
);


//l1 arbiter intf
logic [1:0] l1_reqs;
logic l1_grant_taken;
logic l1_grant_index;
logic l1_grant_valid;

//TODO: need to assign sq_l1_req_valid when inst l1
assign l1_reqs = {sq_l1_req_valid, lq_l1_req_valid};
assign l1_grant_taken = req_ready && (sq_l1_req_valid | lq_l1_req_valid) ;

rr_arbiter  # (
    .N(2)
) u_select_l1_req (
    .clk(clk),
    .rst_n(rst_n),

    .reqs(l1_reqs),
    .grant_taken(l1_grant_taken), //from l1

    .grant_index(l1_grant_index),
    .grant_valid(l1_grant_valid)
);

//l1 intf
logic [XLEN-1:0] req_word_addr;
logic [3:0] req_bytes_accessed;
logic [XLEN-1:0] req_write_data;

assign req_word_addr = l1_grant_index ? sq_l1_req_addr : lq_l1_req_addr;
assign req_bytes_accessed = l1_grant_index ? sq_l1_req_byte_mask : lq_l1_req_byte_mask;
//TODO: connect to req_write_data to drain_write_data from sq
assign req_write_data = 

l1_cache u_l1_cache(
    .clk(clk),
    .rst_n(rst_n),

    // capable of performing 1 load/store per cycle
    .req_valid(l1_grant_valid),
    .req_ready(req_ready),

    .req_is_store(l1_grant_index), //works because req 1 is from sq
    .req_word_addr(req_word_addr),
    .req_bytes_accessed(req_bytes_accessed),
    .req_write_data(req_write_data),

    // tag memory requests
    .req_ld_id(lq_l1_req_ld_id),
    input st_idx_t req_st_id,
    
    // cache responses
    .resp_valid(l1_resp_valid),
    .resp_hit(l1_resp_hit),
    .resp_is_store(resp_is_store),
    .resp_read_data(l1_resp_data),
    .resp_ld_id(l1_resp_ld_id),
    output st_idx_t resp_st_id,

    // send miss to MSHR
    output logic miss_valid,
    input logic miss_ready,
    output line_addr_t miss_line_addr,
    output logic [WORD_SEL_BITS-1:0] miss_critical_word,
    output logic miss_is_store,
    output lq_idx_t miss_ld_id,

    // fill from MSHR
    input logic fill_valid,
    output logic fill_ready,
    input line_pkd_t fill_line,

    // eviction to victim buffer
    output logic victim_valid,
    input logic victim_ready,
    output line_pkd_t victim_line 
);

mshr_file u_mshr_file (
    .clk(clk),
    .rst_n(rst_n),

    // load-miss from L1
    input logic miss_valid,
    output logic miss_ready,
    input line_addr_t miss_line_addr,
    input logic [WORD_SEL_BITS-1:0] miss_critical_word, // tentatively unused, figure out arb first
    input logic miss_is_store,
    input lq_idx_t miss_ld_id,      // tentatively unused, figure out early restart later

    // fill to L1 & broadcast line addr to LQ
    output logic fill_valid,
    input logic fill_ready,
    output line_pkd_t fill_line,

    .wake_valid(wake_valid),
    .wake_line_addr(wake_line_addr),

    // check eviction (L1 -> L2) buffer for hit
    output logic eb_probe_valid,
    output line_addr_t eb_probe_line_addr,
    input logic eb_probe_retry,
    input logic eb_probe_hit,
    input line_pkd_t eb_probe_line,

    // check L2 for hit
    output logic l2_req_valid,
    input logic l2_req_ready,
    output mshr_id_t l2_req_mshr_id,
    output line_addr_t l2_line_addr,

    input logic l2_resp_valid,
    input logic l2_resp_hit,
    input line_pkd_t l2_resp_line,
    input mshr_id_t l2_resp_mshr_id,

    // check wb (L2 -> MEM) buffer 
    // (tentatively, wb is basically eb and doesn't allow data in transit to get sent to mshr)
    output logic wb_probe_valid,
    output line_addr_t wb_probe_line_addr,
    input logic wb_probe_retry,
    input logic wb_probe_hit,
    input line_pkd_t wb_probe_line,

    // check main memory via arbiter interface
    output logic mem_req_valid,
    input logic mem_req_ready,
    output line_addr_t mem_req_line_addr,
    output mshr_id_t mem_req_mshr_id,

    input logic mem_resp_valid,
    input line_data_t mem_resp_data,
    input mshr_id_t mem_resp_mshr_id
);



endmodule
