import mem_pkg::*;

// eviction buffer b/w l1 and l2, waiting for l2 to pick a victim then fill
// mshrs may also snoop the eb
// also currently eb has single serial L2 port, so can only fill one at a time
module eviction_buffer (
    input logic clk,
    input logic rst_n,

    // victims from L1
    input logic l1_victim_valid,
    output logic l1_victim_ready,
    input line_pkd_t l1_victim_line,

    // fill L2
    input logic l2_fill_ready,
    output logic l2_fill_valid,
    output line_pkd_t l2_fill_line,
    input logic l2_ins_done,        // cannot remove the item from eb until l2 raises this (else data dropped)

    // mshr snooping
    input logic mshr_probe_valid,
    input line_addr_t mshr_line_addr,
    output logic mshr_probe_retry,
    output logic mshr_probe_hit,
    output line_pkd_t mshr_probe_line
);

    // buffer & bitmaps indicating what entries are valid
    line_pkd_t evict_buffer [0:EB_SIZE-1];
    logic [EB_SIZE-1:0] valid_entries;

    // keep track of single fill to L2
    logic transit_valid;
    eb_way_ptr_t entry_in_transit;

    assign l1_victim_ready = !(&valid_entries);
    assign l2_fill_valid = |(valid_entries) && !transit_valid;

    // find lowest nonvalid index
    eb_way_ptr_t lowest_invalid_way;
    
    always_comb begin : find_invalid_way
        lowest_invalid_way = 0;
        for (int i = EB_SIZE - 1; i >= 0; i--) begin
            if (!valid_entries[i]) begin
                lowest_invalid_way = eb_way_ptr_t'(i);
            end
        end
    end

    // find lowest valid index
    eb_way_ptr_t lowest_valid_way;
    assign l2_fill_line = evict_buffer[lowest_valid_way];

    always_comb begin : find_lowest_valid_way
        lowest_valid_way = 0;
        for (int i = EB_SIZE - 1; i >= 0; i--) begin
            if (valid_entries[i] & !transit_valid) begin
                lowest_valid_way = eb_way_ptr_t'(i);
            end
        end
    end

    // mshr snoop handling
    eb_way_ptr_t mshr_probe_matching_entry;
    logic mshr_probe_match;

    always_comb begin : find_mshr_match
        mshr_probe_match = 1'b0;
        mshr_probe_matching_entry = '0;

        for (int i = 0; i < EB_SIZE; i++) begin
            if ((evict_buffer[i].line_addr == mshr_line_addr) && valid_entries[i]) begin
                mshr_probe_match = 1'b1;
                mshr_probe_matching_entry = eb_way_ptr_t'(i);
            end
        end
    end

    // can only successfully hit if it's not in transit; if in transit, force retry until data is sent to L2
    assign mshr_probe_hit = mshr_probe_valid && mshr_probe_match && 
                            (!transit_valid || (mshr_probe_matching_entry != entry_in_transit)) &&
                            !((mshr_probe_matching_entry == lowest_valid_way) && (l2_fill_valid && l2_fill_ready));

    // special case: if l2 fill handshake & mshr probe collide, give prio to l2 fill
    assign mshr_probe_retry = mshr_probe_valid && mshr_probe_match && 
                              (((transit_valid) && (mshr_probe_matching_entry == entry_in_transit)) || 
                              (mshr_probe_matching_entry == lowest_valid_way) && (l2_fill_valid && l2_fill_ready));

    assign mshr_probe_line = evict_buffer[mshr_probe_matching_entry];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            valid_entries <= '0;
            transit_valid <= 1'b0;
        end else begin
            if (l1_victim_valid && l1_victim_ready) begin
                valid_entries[lowest_invalid_way] <= 1'b1;
                evict_buffer[lowest_invalid_way] <= l1_victim_line;
            end

            if (l2_fill_valid && l2_fill_ready) begin
                entry_in_transit <= lowest_valid_way;
                transit_valid <= 1'b1;
            end

            if (l2_ins_done) begin
                transit_valid <= 1'b0;
                valid_entries[entry_in_transit] <= 1'b0;
            end

            if (mshr_probe_hit) begin
                valid_entries[mshr_probe_matching_entry] <= 1'b0;
            end
        end
    end

endmodule
