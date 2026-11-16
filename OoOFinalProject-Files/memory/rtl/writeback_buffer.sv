import mem_pkg::*;

// copied from eviction buffer, but interfaces L2 and memory arbiter, mshrs snoop through
module writeback_buffer (
    input logic clk,
    input logic rst_n,

    // victims from L2
    input logic l2_victim_valid,
    output logic l2_victim_ready,
    input line_pkd_t l2_victim_line,

    // send to memory
    input logic arb_write_ready,
    output logic arb_write_valid,
    output line_pkd_t arb_fill_line,
    input logic arb_ins_done,        // cannot remove the item from wb until mem raises this

    // mshr snooping
    input logic mshr_probe_valid,
    input line_addr_t mshr_line_addr,
    output logic mshr_probe_retry,
    output logic mshr_probe_hit,
    output line_pkd_t mshr_probe_line
);

    // buffer & bitmaps indicating what entries are valid
    line_pkd_t write_buffer [0:WB_SIZE-1];
    logic [WB_SIZE-1:0] valid_entries;

    // keep track of single fill to L2
    logic transit_valid;
    wb_way_ptr_t entry_in_transit;

    assign l2_victim_ready = !(&valid_entries);
    assign arb_write_valid = |(valid_entries) && !transit_valid;

    // find lowest nonvalid index
    wb_way_ptr_t lowest_invalid_way;
    
    always_comb begin : find_invalid_way
        lowest_invalid_way = 0;
        for (int i = WB_SIZE - 1; i >= 0; i--) begin
            if (!valid_entries[i]) begin
                lowest_invalid_way = wb_way_ptr_t'(i);
            end
        end
    end

    // find lowest valid index
    wb_way_ptr_t lowest_valid_way;
    assign arb_write_line = write_buffer[lowest_valid_way];

    always_comb begin : find_lowest_valid_way
        lowest_valid_way = 0;
        for (int i = WB_SIZE - 1; i >= 0; i--) begin
            if (valid_entries[i] & !transit_valid) begin
                lowest_valid_way = wb_way_ptr_t'(i);
            end
        end
    end

    // mshr snoop handling
    wb_way_ptr_t mshr_probe_matching_entry;
    logic mshr_probe_match;

    always_comb begin : find_mshr_match
        mshr_probe_match = 1'b0;
        mshr_probe_matching_entry = '0;

        for (int i = 0; i < WB_SIZE; i++) begin
            if ((write_buffer[i].line_addr == mshr_line_addr) && valid_entries[i]) begin
                mshr_probe_match = 1'b1;
                mshr_probe_matching_entry = wb_way_ptr_t'(i);
            end
        end
    end

    // can only successfully hit if it's not in transit; if in transit, force retry until data is sent to mem
    assign mshr_probe_hit = mshr_probe_valid && mshr_probe_match && 
                            (!transit_valid || (mshr_probe_matching_entry != entry_in_transit)) &&
                            !((mshr_probe_matching_entry == lowest_valid_way) && (arb_write_valid && arb_write_ready));

    // special case: if mem fill handshake & mshr probe collide, give prio to mem fill
    assign mshr_probe_retry = mshr_probe_valid && mshr_probe_match && 
                              (((transit_valid) && (mshr_probe_matching_entry == entry_in_transit)) || 
                              (mshr_probe_matching_entry == lowest_valid_way) && (arb_write_valid && arb_write_ready));

    assign mshr_probe_line = write_buffer[mshr_probe_matching_entry];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_entries <= '0;
            transit_valid <= 1'b0;
        end else begin
            if (l2_victim_valid && l2_victim_ready) begin
                valid_entries[lowest_invalid_way] <= 1'b1;
                write_buffer[lowest_invalid_way] <= l2_victim_line;
            end

            if (arb_write_valid && arb_write_ready) begin
                entry_in_transit <= lowest_valid_way;
                transit_valid <= 1'b1;
            end

            if (arb_ins_done) begin
                transit_valid <= 1'b0;
                valid_entries[entry_in_transit] <= 1'b0;
            end

            if (mshr_probe_hit) begin
                valid_entries[mshr_probe_matching_entry] <= 1'b0;
            end
        end
    end

endmodule
