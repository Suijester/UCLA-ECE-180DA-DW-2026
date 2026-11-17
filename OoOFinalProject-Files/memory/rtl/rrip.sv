import mem_pkg::*;

// combinational rrip module
module rrip (
    input logic [L2_WAYS-1:0] l2_valid,
    input logic [1:0] rrpv [0:L2_WAYS-1],
    input logic fill_line_reuse,

    output l2_way_ptr_t victim_way,
    output logic [1:0] new_rrpv [0:L2_WAYS-1],
    output logic eviction_occurred
);

    assign eviction_occurred = &l2_valid;

    always_comb begin
        victim_way = 0;
        new_rrpv = rrpv;

        // find invalid way
        if (!eviction_occurred) begin
            for (int i = L2_WAYS-1; i >= 0; i--) begin
                if (!l2_valid[i]) begin
                    victim_way = l2_way_ptr_t'(i);
                end
            end

            new_rrpv[victim_way] = (fill_line_reuse) ? 2'd0 : 2'd2;
        end

        // find highest rrpv and make that the new victim
        else begin

        end
    end

endmodule