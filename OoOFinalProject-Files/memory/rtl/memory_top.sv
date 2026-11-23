// Memory team top. Port list matches the instructor's rv32_ooo_top.
import rv32_ooo_pkg::*;
import mem_pkg::*;

module memory_top(
    input logic clk,
    input logic rst_n,

    backend_memory_if.memory backend_if,
    data_memory_if.client dmem_if,
    frontend_backend_if.monitor fe_be_if,


    //TODO: check with frontend what the name of their dispatch if is
    input logic disp_valid, //wr_en
    input renamed_uop_t disp_inst, //currently 1 wide allocation
    output logic disp_ready
);

//TODO: check to make sure understanding of busy is right
assign backend_if.busy = !sq_empty || !lq_empty;

logic is_load, is_store;

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

//output to dispatch
logic lq_disp_ready, sq_disp_ready;
logic disp_is_load, disp_is_store;

assign disp_is_load = disp_inst.decoded.mem_cmd == MEM_LOAD;
assign disp_is_store = disp_inst.decoded.mem_cmd == MEM_STORE;

assign disp_ready = (disp_is_load && lq_disp_ready) || (disp_is_store && sq_disp_ready);

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
logic load_out_under_unresolved_branch;
phys_reg_t load_out_writeback_pdst;

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

logic lq_full, lq_empty;

assign backend_if.issue_ready = is_load && lq_issue_ready || is_store && sq_issue_ready ;

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
    .disp_valid(disp_valid && disp_is_load), //wr_en
    .disp_inst(disp_inst), //currently 1 wide allocation
    .disp_ready(lq_disp_ready), 

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
    .retire_valid(fe_be_if.retire_valid),
    .retire_rob_tag(fe_be_if.retire_tag),

    //from store_queue   
    .sq_tail(sq_tail),

    //to store forward
    .check_valid(sq_check_valid), //unused
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
    .load_out_under_unresolved_branch(load_out_under_unresolved_branch),
    .load_out_writeback_pdst(load_out_writeback_pdst),

    //to L1 cache
    .l1_req_valid(lq_l1_req_valid),
    .l1_req_addr(lq_l1_req_addr),
    .l1_req_ready(req_ready && l1_grant_valid && !l1_grant_index),
    .l1_req_byte_mask(lq_l1_req_byte_mask),
    .l1_req_ld_id(lq_l1_req_ld_id),

    //from L1 cache
    .l1_resp_valid(l1_resp_valid && !resp_is_store),
    .l1_resp_hit(l1_resp_hit),
    .l1_resp_ld_id(l1_resp_ld_id),
    .l1_resp_data(l1_resp_data),

    //mshr wakeup
    .wake_valid(wake_valid),
    .wake_line_addr(wake_line_addr),

    .full(lq_full),
    .empty(lq_empty)

);

load_result u_load_result (
    .clk(clk),
    .rst_n(rst_n),

    .lq_out(load_out), 
    .load_out_valid(load_out_valid),
    .load_out_ready(load_out_ready),
    .load_out_rob_tag(load_out_rob_tag),
    .load_out_mem_size(load_out_mem_size),
    .load_out_byte_offset(load_out_byte_offset),
    .load_out_unsigned(load_out_unsigned),
    .load_out_under_unresolved_branch(load_out_under_unresolved_branch),
    .load_out_writeback_pdst(load_out_writeback_pdst),

    //from store_queue
    .store_out_valid(sq_out_valid),
    .store_out_ready(sq_out_ready),
    .store_out_rob_tag(sq_out_rob_tag),
    .store_out_comp_under_branch(sq_out_comp_under_branch),
    

    //to writeback/rob
    .result_valid(backend_if.result_valid),
    .result_ready(backend_if.result_ready),
    .result(backend_if.result)
);

//store queue
st_ptr_t sq_disp_st_ptr;

//sq_issue
logic sq_issue_ready;

//sq - load_result if
logic sq_out_valid;
logic sq_out_ready;
rob_tag_t sq_out_rob_tag;
logic sq_out_comp_under_branch;

//sq - store_sets
logic [SQ_SIZE-1:0] sq_squash_mask;

//sq - store_forward
st_ptr_t sq_head;
logic [SQ_SIZE-1:0] sq_valid;
logic [SQ_SIZE-1:0] sq_addr_valid;        // address/data filled at issue
logic [XLEN-1:0] sq_word_addr [SQ_SIZE];
logic [3:0] sq_bytes_accessed [SQ_SIZE];
logic [XLEN-1:0] sq_write_data [SQ_SIZE];

//sq -> l1 if
logic sq_l1_req_valid;
logic [XLEN-1:0] drain_write_data;         // -> req_write_data
st_idx_t drain_st_id; 

//l1 -> sq if 
st_idx_t drain_resp_st_id;

//sq status
logic sq_empty;                            // feeds be.busy: retired stores not yet in L1
logic sq_full;

logic [XLEN-1:0] sq_l1_req_addr;
logic [3:0]      sq_l1_req_byte_mask;


store_queue u_store_queue (
    .clk(clk),
    .rst_n(rst_n),

    // dispatch (same shape as load_queue: one instruction per cycle)
    .disp_valid(disp_valid && disp_is_store),                           // a store is dispatching
    .disp_inst(disp_inst),
    .disp_ready(sq_disp_ready),                          // low when full (backend stalls dispatch)
    .disp_st_ptr(sq_disp_st_ptr),                      // slot this store gets (store_sets, later)

    // issue (from address_gen): fill the entry with this ROB tag
    .issue_valid(backend_if.issue_valid && is_store),
    .issue_ready(sq_issue_ready),
    .issue_rob_tag(backend_if.issue_uop.rob_tag),
    .issue_word_addr(agu_word_addr),           // address_gen.word_addr
    .issue_bytes_accessed(agu_bytes_accessed),           // address_gen.bytes_accessed
    .issue_write_data(agu_store_data),          // address_gen.store_data (copied into every lane)

    // completion to the ROB, valid/ready: held constant until comp_ready
    // (load_result packs execution_result_t with writeback_valid = 0)
    .comp_valid(sq_out_valid),
    .comp_ready(sq_out_ready),
    .comp_rob_tag(sq_out_rob_tag),
    .comp_under_branch(sq_out_comp_under_branch),

    // retirement and branch recovery
    .rob_head_tag(backend_if.rob_head_tag),                     // be.rob_head_tag
    .br_resolve_valid(fe_be_if.branch_resolve_valid),
    .br_mispredict(fe_be_if.branch_mispredict),
    .sq_squash_mask(sq_squash_mask),        // slots freed by this mispredict (store_sets)

    // forwarding view (to store_forward)
    .sq_head(sq_head),
    .sq_tail(sq_tail),                          // a new load records this: its older stores are head..tail-1
    .sq_valid(sq_valid),
    .sq_addr_valid(sq_addr_valid),         // address/data filled at issue
    .sq_word_addr(sq_word_addr),
    .sq_bytes_accessed(sq_bytes_accessed),
    .sq_write_data(sq_write_data),

    // drain request to L1 (memory_top drives l1_cache req_* with req_is_store = 1)
    .drain_valid(sq_l1_req_valid),
    .drain_ready(req_ready && l1_grant_valid && l1_grant_index),                          // l1_cache req_ready, and the L1 port arbiter picked us
    .drain_word_addr(sq_l1_req_addr),          // -> req_word_addr
    .drain_bytes_accessed(sq_l1_req_byte_mask),          // -> req_bytes_accessed
    .drain_write_data(drain_write_data),         // -> req_write_data
    .drain_st_id(drain_st_id),                      // -> req_st_id

    // drain response from L1 (memory_top passes l1_cache resp_* when resp_is_store = 1)
    .drain_resp_valid(l1_resp_valid && resp_is_store),
    .drain_resp_hit(l1_resp_hit),
    .drain_resp_st_id(drain_resp_st_id),

    // line filled by an MSHR (mshr_file wake_*): a store that missed can retry
    .wake_valid(wake_valid),
    .wake_line_addr(wake_line_addr),

    // status
    .sq_empty(sq_empty),                            // feeds be.busy: retired stores not yet in L1
    .sq_full(sq_full)
);


store_forward u_store_forward (
    //the load
    .ld_word_addr(sq_check_addr),              // address_gen.word_addr
    .ld_bytes_accessed(sq_check_byte_mask),              // address_gen.bytes_accessed
    .ld_sq_tail(sq_check_tail),                        // SQ tail when the load was allocated

    // store queue view: store_queue sq_* outputs
    .sq_head(sq_head),
    .sq_valid(sq_valid),
    .sq_addr_valid(sq_addr_valid),          // store's address/data filled at issue
    .sq_word_addr(sq_word_addr),
    .sq_bytes_accessed(sq_bytes_accessed),
    .sq_write_data(sq_write_data),

    // cache word (l1_cache resp_read_data, or the MSHR early-restart word)
    //TODO: check about the necessity of cache_read_data
    .cache_read_data('b0),

    // result (to load_result for extract / extend)
   .fwd_data(sq_fwd_data),
    .fwd_bytes_from_store(sq_fwd_bytes),          // which bytes came from a store
    .fwd_all_from_store(sq_fwd_all),                 // every needed byte forwarded: cache not needed
    // conservative disambiguation: an older store has no address yet, so the
    // load can't tell whether it depends on it -> the load must wait
    .sq_stall(sq_stall)
);


//l1 arbiter intf
logic [1:0] l1_reqs;
logic l1_grant_taken;
logic l1_grant_index;
logic l1_grant_valid;

assign l1_reqs = {sq_l1_req_valid, lq_l1_req_valid};
assign l1_grant_taken = req_ready && l1_grant_valid; //issued a request and l1 took it

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
assign req_write_data = l1_grant_index ? drain_write_data: 'b0;

//l1 -> mshr
logic miss_valid;
logic miss_ready;
line_addr_t miss_line_addr;
logic [WORD_SEL_BITS-1:0] miss_critical_word;
logic miss_is_store;
lq_idx_t miss_ld_id;

//mshr -> l1
logic fill_valid;
logic fill_ready;
line_pkd_t fill_line;

//l1 -> eb
logic l1_victim_valid;
logic l1_victim_ready;
line_pkd_t l1_victim_line;

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
    .req_st_id(drain_st_id),
    
    // cache responses
    .resp_valid(l1_resp_valid),
    .resp_hit(l1_resp_hit),
    .resp_is_store(resp_is_store),
    .resp_read_data(l1_resp_data),
    .resp_ld_id(l1_resp_ld_id),
    .resp_st_id(drain_resp_st_id),

    // send miss to MSHR
    .miss_valid(miss_valid),
    .miss_ready(miss_ready),
    .miss_line_addr(miss_line_addr),
    .miss_critical_word(miss_critical_word),
    .miss_is_store(miss_is_store),
    .miss_ld_id(miss_ld_id),

    // fill from MSHR
    .fill_valid(fill_valid),
    .fill_ready(fill_ready),
    .fill_line(fill_line),

    // eviction to victim buffer
    .victim_valid(l1_victim_valid),
    .victim_ready(l1_victim_ready),
    .victim_line(l1_victim_line) 
);

eviction_buffer u_eviction_buffer (
    .clk(clk),
    .rst_n(rst_n),

    // victims from L1
    .l1_victim_valid(l1_victim_valid),
    .l1_victim_ready(l1_victim_ready),
    .l1_victim_line(l1_victim_line),

    // fill L2
    .l2_fill_ready(l2_fill_ready),
    .l2_fill_valid(l2_fill_valid),
    .l2_fill_line(l2_fill_line),
    .l2_ins_done(l2_ins_done),        // cannot remove the item from eb until l2 raises this (else data dropped)

    // mshr snooping
    .mshr_probe_valid(eb_probe_valid),
    .mshr_line_addr(eb_probe_line_addr),
    .mshr_probe_retry(eb_probe_retry),
    .mshr_probe_hit(eb_probe_hit),
    .mshr_probe_line(eb_probe_line)
);

//mshr -> eb
logic eb_probe_valid;
line_addr_t eb_probe_line_addr;
logic eb_probe_retry;
logic eb_probe_hit;
line_pkd_t eb_probe_line;

//l2 -> mshr
logic l2_req_valid;
logic l2_req_ready;
mshr_id_t l2_req_mshr_id;
line_addr_t l2_line_addr;

//mshr -> l2
logic mshr_resp_valid;
logic mshr_resp_hit;
line_pkd_t mshr_resp_line;
mshr_id_t mshr_resp_id;

//eb -> l2
logic l2_fill_ready;
logic l2_fill_valid;
line_pkd_t l2_fill_line;
logic l2_ins_done;

//mshr -> wb
logic mshr_probe_valid;
line_addr_t mshr_line_addr;
logic mshr_probe_retry;
logic mshr_probe_hit;
line_pkd_t mshr_probe_line;



mshr_file u_mshr_file (
    .clk(clk),
    .rst_n(rst_n),

    // load-miss from L1
    .miss_valid(miss_valid),
    .miss_ready(miss_ready),
    .miss_line_addr(miss_line_addr),
    .miss_critical_word(miss_critical_word), // tentatively unused, figure out arb first
    .miss_is_store(miss_is_store),
    .miss_ld_id(miss_ld_id),      // tentatively unused, figure out early restart later

    // fill to L1 & broadcast line addr to LQ
    .fill_valid(fill_valid),
    .fill_ready(fill_ready),
    .fill_line(fill_line),

    .wake_valid(wake_valid),
    .wake_line_addr(wake_line_addr),

    // check eviction (L1 -> L2) buffer for hit
    .eb_probe_valid(eb_probe_valid),
    .eb_probe_line_addr(eb_probe_line_addr),
    .eb_probe_retry(eb_probe_retry),
    .eb_probe_hit(eb_probe_hit),
    .eb_probe_line(eb_probe_line),

    // check L2 for hit
    .l2_req_valid(l2_req_valid),
    .l2_req_ready(l2_req_ready),
    .l2_req_mshr_id(l2_req_mshr_id),
    .l2_line_addr(l2_line_addr),

    .l2_resp_valid(mshr_resp_valid),
    .l2_resp_hit(mshr_resp_hit),
    .l2_resp_line(mshr_resp_line),
    .l2_resp_mshr_id(mshr_resp_id),

    // check wb (L2 -> MEM) buffer 
    // (tentatively, wb is basically eb and doesn't allow data in transit to get sent to mshr)
    .wb_probe_valid(mshr_probe_valid),
    .wb_probe_line_addr(mshr_line_addr),
    .wb_probe_retry(mshr_probe_retry),
    .wb_probe_hit(mshr_probe_hit),
    .wb_probe_line(mshr_probe_line),

    // check main memory via arbiter interface
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_line_addr(mem_req_line_addr),
    .mem_req_mshr_id(mem_req_mshr_id),

    .mem_resp_valid(mem_resp_valid),
    .mem_resp_data(mem_resp_data),
    .mem_resp_mshr_id(mem_resp_mshr_id)
);

l2_cache u_l2_cache (
    .clk(clk),
    .rst_n(rst_n),

    // MSHR snooping ports
    .mshr_req_valid(l2_req_valid),
    .mshr_req_ready(l2_req_ready),
    .mshr_req_id(l2_req_mshr_id),
    .mshr_req_line_addr(l2_line_addr),

    .mshr_resp_valid(mshr_resp_valid),
    .mshr_resp_hit(mshr_resp_hit),
    .mshr_resp_line(mshr_resp_line),
    .mshr_resp_id(mshr_resp_id),

    // fill ports from eviction buffer
    .l2_fill_ready(l2_fill_ready),
    .l2_fill_valid(l2_fill_valid),
    .l2_fill_line(l2_fill_line),
    .l2_ins_done(l2_ins_done),

    // send victim to writeback buffer
    .l2_victim_valid(l2_victim_valid),
    .l2_victim_ready(l2_victim_ready),
    .l2_victim_line(l2_victim_line)
);

//l2 -> wb
logic l2_victim_valid;
logic l2_victim_ready;
line_pkd_t l2_victim_line;

writeback_buffer u_writeback_buffer (
    .clk(clk),
    .rst_n(rst_n),

    // victims from L2
    .l2_victim_valid(l2_victim_valid),
    .l2_victim_ready(l2_victim_ready),
    .l2_victim_line(l2_victim_line),

    // send to memory
    .arb_write_ready(arb_write_ready),
    .arb_write_valid(arb_write_valid),
    .arb_write_line(arb_write_line),
    .arb_write_done(arb_write_done),        // cannot remove the item from wb until mem raises this

    // mshr snooping
    .mshr_probe_valid(mshr_probe_valid),
    .mshr_line_addr(mshr_line_addr),
    .mshr_probe_retry(mshr_probe_retry),
    .mshr_probe_hit(mshr_probe_hit),
    .mshr_probe_line(mshr_probe_line)
);

//mshr -> main mem
logic mem_req_valid;
logic mem_req_ready;
line_addr_t mem_req_line_addr;
mshr_id_t mem_req_mshr_id;

logic mem_resp_valid;
line_data_t mem_resp_data;
mshr_id_t mem_resp_mshr_id;

//wb -> main mem
logic arb_write_ready;
logic arb_write_valid;
line_pkd_t arb_write_line;
logic arb_write_done;


mem_arbiter u_mem_arbiter(
    .clk(clk),
    .rst_n(rst_n),

    // mshr data accesses
    .mem_req_valid(mem_req_valid),
    .mem_req_ready(mem_req_ready),
    .mem_req_line_addr(mem_req_line_addr),
    .mem_req_mshr_id(mem_req_mshr_id),

    .mem_resp_valid(mem_resp_valid),
    .mem_resp_data(mem_resp_data),
    .mem_resp_mshr_id(mem_resp_mshr_id),

    // writeback data writes
    .arb_write_ready(arb_write_ready),
    .arb_write_valid(arb_write_valid),
    .arb_write_line(arb_write_line),
    .arb_write_done(arb_write_done),

    // modport interface
    .ram(dmem_if)
);

endmodule
