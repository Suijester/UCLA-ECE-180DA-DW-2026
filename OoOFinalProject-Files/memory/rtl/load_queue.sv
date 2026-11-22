// Load queue
import rv32_ooo_pkg::*;
import mem_pkg::*;

module load_queue (
    input logic clk,
    input logic rst_n,

    //from dispatch
    input logic disp_valid, //wr_en
    input renamed_uop_t disp_inst, //currently 1 wide allocation
    output logic disp_ready, 

    //from address_gen, after issue
    input logic [XLEN-1:0] word_addr,      // word-level address, w/o byte-level access (i.e. word_addr[1:0] == 2'b00)
    input logic [1:0] byte_offset,         // byte-level access
    input logic [3:0] bytes_accessed,      // 0011 accesses first half, 1000 accesses last byte, etc. (identifies size of access, e.g. sh/sw/lh/lw)
    input logic misaligned_access,
    input rob_tag_t issue_rob_tag,
    input logic issue_valid,
    output logic issue_ready,

    //from retire
    input logic retire_valid,
    input rob_tag_t retire_rob_tag,

    //from store_queue
    input st_ptr_t sq_tail,

    //to store forward
    output logic check_valid,
    output logic [XLEN-1:0] check_addr,
    output logic [3:0] check_byte_mask,
    output st_ptr_t check_sq_tail,
 

    //from store_forward
    input logic [XLEN-1:0] fwd_data,
    input logic [3:0] fwd_bytes_from_store,
    input logic fwd_all_from_store,

    input logic sq_stall,

    //forwarded to load_result
    output logic [XLEN-1:0] load_out, 
    output logic load_out_valid,
    input logic load_out_ready,
    output rob_tag_t load_out_rob_tag,
    output mem_size_e load_out_mem_size,
    output logic [1:0] load_out_byte_offset,
    output logic load_out_unsigned,
    output logic load_out_under_unresolved_branch,
    output phys_reg_t load_out_writeback_pdst,

    //to L1 cache
    output logic l1_req_valid,
    output logic [XLEN-1:0] l1_req_addr,
    input logic l1_req_ready,
    output logic [3:0]      l1_req_byte_mask,
    output lq_idx_t l1_req_ld_id,

    //from L1 cache
    input logic l1_resp_valid,
    input logic l1_resp_hit,
    input lq_idx_t l1_resp_ld_id,
    input logic [XLEN-1:0] l1_resp_data,

    //mshr wakeup
    input logic wake_valid,
    input line_addr_t wake_line_addr

);

lq_entry_t lq [LQ_SIZE];
lq_idx_t head, tail;
logic [$clog2(LQ_SIZE):0] count, count_d;
logic full, empty;

logic dispatch_fire, retire_fire;

logic req_held;
lq_idx_t held_req_idx;

assign full = count == LQ_SIZE;
assign empty = count == 0;

assign disp_ready = !full;
assign dispatch_fire = disp_valid && disp_ready;
assign retire_fire = retire_valid && !empty && lq[head].valid && (lq[head].rob_tag == retire_rob_tag) && lq[head].executed;

//pass oldest eligible load to sq for dependency checking
assign check_valid = check_found;
assign check_addr = lq[check_idx].addr;
assign check_byte_mask = lq[check_idx].byte_mask;
assign check_sq_tail = lq[check_idx].sq_tail_snapshot;


always_ff @ (posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        head <= '0;
        tail <= '0;
        count <= '0;
        result_held <= 1'b0;
        held_result_idx <= '0;
        req_held <= 'b0;
        held_req_idx <= 'b0;

        for (int i = 0; i < LQ_SIZE; i++) begin
            lq[i] <= 'b0;
        end

    end else begin
        if (dispatch_fire) begin
            //assign fields
            lq[tail].valid <= 'b1;
            lq[tail].rob_tag <= disp_inst.rob_tag;
            lq[tail].addr <= 'b0;
            lq[tail].addr_valid <= 'b0;
            lq[tail].byte_mask <= 'b0;
            lq[tail].byte_offset <= 'b0;
            lq[tail].mem_size <= disp_inst.decoded.mem_size;
            lq[tail].load_unsigned <= disp_inst.decoded.load_unsigned;
            lq[tail].writeback_pdst <= disp_inst.pdst;
            lq[tail].under_unresolved_branch <= disp_inst.under_unresolved_branch;
            lq[tail].executed <= 'b0; 
            lq[tail].sq_checked <= 'b0;
            lq[tail].l1_waiting <= 'b0;
            lq[tail].result_data <= 'b0;
            lq[tail].fwd_mask <= 'b0;
            lq[tail].fwd_data <= 'b0;            
            lq[tail].result_pending <= 'b0;
            lq[tail].sq_tail_snapshot <= sq_tail;
            lq[tail].wait_wake <= 'b0;
            lq[tail].wake_seen <= 'b0;
            lq[tail].l1_retry <= 'b0;
    

            tail <= tail + 1;
        end 
        
        if (issue_valid && issue_ready && !misaligned_access) begin
            lq[issue_idx].addr <= word_addr;
            lq[issue_idx].byte_mask <= bytes_accessed;
            lq[issue_idx].byte_offset <= byte_offset;
            lq[issue_idx].addr_valid <= 'b1; 
        //TODO: report misaligned address exception to ROB, needs backend exception intf

        end

        if (retire_fire) begin
            lq[head].valid <= 'b0;
            head <= head + 1'b1;

        end

        if (l1_req_fire) begin
            lq[l1_req_ld_id].sq_checked <= 'b1;
            lq[l1_req_ld_id].l1_waiting <= 'b1;
            lq[l1_req_ld_id].l1_retry <= 'b0;
            lq[l1_req_ld_id].wait_wake <= 1'b0;
            lq[l1_req_ld_id].wake_seen <= 1'b0;
        end

        if (load_out_fire) begin
            lq[selected_result_idx].sq_checked <= 'b1;
            lq[selected_result_idx].executed <= 'b1;
            lq[selected_result_idx].result_pending <= 'b0;
        end

        if (check_valid && !sq_stall) begin
            if (fwd_all_from_store) begin
                lq[check_idx].result_data <= fwd_data;
                lq[check_idx].result_pending <= 'b1;
                lq[check_idx].sq_checked <= 'b1;
            end else if (l1_req_fire && l1_req_ld_id == check_idx) begin
                lq[check_idx].fwd_data <= fwd_data;
                lq[check_idx].fwd_mask <= fwd_bytes_from_store;
            end   
                
        end

        if (l1_req_valid && !l1_req_ready && !req_held) begin
            req_held <= 1'b1;
            held_req_idx <= l1_req_ld_id;
            if (!l1_found && check_valid && !sq_stall && !fwd_all_from_store) begin
                lq[check_idx].fwd_data <= fwd_data;
                lq[check_idx].fwd_mask <= fwd_bytes_from_store;
            end
        end else if (l1_req_fire) begin
            req_held <= 1'b0;
        end 

        // Handle L1 response
        if (l1_resp_valid && lq[l1_resp_ld_id].valid && lq[l1_resp_ld_id].l1_waiting) begin
            lq[l1_resp_ld_id].l1_waiting <= 1'b0;

            if (l1_resp_hit) begin
                lq[l1_resp_ld_id].result_pending <= 1'b1;
                lq[l1_resp_ld_id].result_data <= merged_data;
                lq[l1_resp_ld_id].wake_seen <= 1'b0;
            end else begin
                //if wakeup already happened retry now, otherwise wait for mshr
                lq[l1_resp_ld_id].wait_wake <= !(lq[l1_resp_ld_id].wake_seen || wake_match[l1_resp_ld_id]);
                lq[l1_resp_ld_id].l1_retry <= lq[l1_resp_ld_id].wake_seen || wake_match[l1_resp_ld_id];
                lq[l1_resp_ld_id].wake_seen <= 1'b0;
            end
        end

        // handle mshr wakeups independently of l1 responses
        for (int i = 0; i < LQ_SIZE; i++) begin
            if (wake_match[i]) begin
                if (lq[i].wait_wake) begin
                    lq[i].wait_wake <= 1'b0;
                    lq[i].l1_retry <= 1'b1;
                end else if (lq[i].l1_waiting && !(l1_resp_valid && l1_resp_ld_id == lq_idx_t'(i))) begin
                    lq[i].wake_seen <= 1'b1;
                end
            end
        end
        //load_result backpressure handling
        if (load_out_valid && !load_out_ready && !result_held) begin
            result_held <= 1'b1;
            held_result_idx <= selected_result_idx;
        end else if (load_out_fire) begin
            result_held <= 1'b0;
        end

        

        count <= count_d;

    end
end

//logic to find element to update after issue
logic issue_found;
lq_idx_t issue_idx; 

assign issue_ready = issue_found && !lq[issue_idx].addr_valid;

always_comb begin
    issue_found = 'b0;
    issue_idx = '0;

    for (int i = 0; i < LQ_SIZE; i++) begin
        if (lq[i].valid == 1'b1 && lq[i].rob_tag == issue_rob_tag) begin
            issue_found = 1'b1;
            issue_idx = lq_idx_t'(i);
        end
    end
end

always_comb begin
    case ({dispatch_fire, retire_fire}) 
        2'b01: count_d = count - 1;
        2'b10: count_d = count + 1;
        default: count_d = count;
    endcase
end

//determine action based on sq result
always_comb begin: lq_req
    l1_req_valid = 'b0;
    l1_req_addr = 'b0;
    l1_req_byte_mask = 'b0;
    l1_req_ld_id = 'b0;

        //retry awakened load
      if (req_held) begin
        l1_req_valid = 1'b1;
        l1_req_addr = lq[held_req_idx].addr;
        l1_req_byte_mask = lq[held_req_idx].byte_mask;
        l1_req_ld_id = held_req_idx;
      end else if (l1_found) begin
        l1_req_valid = 1'b1;
        l1_req_addr = lq[l1_idx].addr;
        l1_req_byte_mask = lq[l1_idx].byte_mask;
        l1_req_ld_id = l1_idx;
      end else if (check_valid && !sq_stall && !fwd_all_from_store) begin //send request to L1
        l1_req_addr = lq[check_idx].addr;
        l1_req_byte_mask = check_byte_mask;
        l1_req_ld_id = check_idx;
        l1_req_valid = 'b1;
    end
  
end

//assign results
always_comb begin: assign_results
    load_out = '0;
    load_out_valid = 1'b0;
    load_out_rob_tag = '0;
    load_out_mem_size = mem_size_e'('0);
    load_out_byte_offset = '0;
    load_out_unsigned = 1'b0;
    load_out_under_unresolved_branch = 'b0;
    load_out_writeback_pdst = 'b0;

    if (selected_result_valid) begin
        load_out = lq[selected_result_idx].result_data;
        load_out_valid = 1'b1;
        load_out_rob_tag = lq[selected_result_idx].rob_tag;
        load_out_mem_size = lq[selected_result_idx].mem_size;
        load_out_byte_offset = lq[selected_result_idx].byte_offset;
        load_out_unsigned = lq[selected_result_idx].load_unsigned;
        load_out_under_unresolved_branch = lq[selected_result_idx].under_unresolved_branch;
        load_out_writeback_pdst = lq[selected_result_idx].writeback_pdst;
    end
end

//control logic to update state of lq
logic l1_req_fire;
logic load_out_fire;

assign l1_req_fire = l1_req_valid && l1_req_ready;
assign load_out_fire = load_out_valid && load_out_ready;

//partial store forwarding
logic [XLEN-1:0] merged_data;

for (genvar i = 0; i < 4; i++) begin
    assign merged_data[i*8 +: 8] = lq[l1_resp_ld_id].fwd_mask[i]? lq[l1_resp_ld_id].fwd_data[i*8 +: 8] : l1_resp_data[i*8 +: 8];
end

//find oldest load available that has an available addr and hasn't been checked
logic check_found;
lq_idx_t check_idx;

always_comb begin: find_oldest_load
    check_found = 1'b0;
    check_idx = 'b0;

    for (int i = 0; i < LQ_SIZE; i++) begin
        lq_idx_t idx;
        idx = head+lq_idx_t'(i);

        if (!check_found && lq[idx].valid && lq[idx].addr_valid && !lq[idx].sq_checked && !(req_held && held_req_idx == idx)) begin
            check_found = 1'b1;
            check_idx = idx;
        end
    end
end

//if can't send l1 response to load_result immediately, in
logic result_found;
lq_idx_t result_idx;



always_comb begin : find_oldest_result
    result_found = 1'b0;
    result_idx = '0;

    for (int i = 0; i < LQ_SIZE; i++) begin
        lq_idx_t idx;
        idx = head + lq_idx_t'(i);

        if (!result_found &&
            lq[idx].valid &&
            lq[idx].result_pending) begin

            result_found = 1'b1;
            result_idx = idx;
        end
    end
end

// find oldest l1 relative to head
logic l1_found;
lq_idx_t l1_idx;

always_comb begin : find_oldest_l1
    l1_found = 1'b0;
    l1_idx = '0;

    for (int offset = 0; offset < LQ_SIZE; offset++) begin
        int idx;
        idx = (int'(head) + offset) % LQ_SIZE;

        if (!l1_found &&
            lq[idx].valid &&
            lq[idx].l1_retry &&
            !lq[idx].l1_waiting &&
            !lq[idx].wait_wake) begin

            l1_found = 1'b1;
            l1_idx = lq_idx_t'(idx);
        end
    end
end

//load result control logic for backpressure
logic result_held;
lq_idx_t held_result_idx;

lq_idx_t selected_result_idx;
logic selected_result_valid;

always_comb begin
    selected_result_valid = result_held || result_found;
    selected_result_idx = result_held ? held_result_idx : result_idx;
end

//finding eligible entries from mshr wakeup
logic [LQ_SIZE-1:0] wake_match;

always_comb begin: find_mshr_wakeup
    for (int i = 0; i < LQ_SIZE; i++) begin
        wake_match[i] = wake_valid &&
            lq[i].valid &&
            (lq[i].addr[XLEN-1:OFFSET_BITS] == wake_line_addr);
    end
end

endmodule


