// standard rr arb using two fixed prio arb, outputs binary index by internally decoding onehot vector
module rr_arbiter # (
    parameter N = 32
) (
    input logic clk,
    input logic rst_n,

    input logic [N-1:0] reqs,
    input logic grant_taken,

    output logic [$clog2(N)-1:0] grant_index,
    output logic grant_valid
);

    logic [N-1:0] prio_mask, selected_grants, prio_grants, grants;
    assign selected_grants = (|prio_grants) ? prio_grants : grants;
    assign grant_valid = |selected_grants;

    function automatic logic [N-1:0] fixed_prio_arb (input logic [N-1:0] requests);
        return requests & (~requests + 1);
    endfunction

    assign grants = fixed_prio_arb(reqs);
    assign prio_grants = fixed_prio_arb(reqs & prio_mask);

    always_comb begin
        grant_index = 0;
        for (int i = N - 1; i >= 0; i--) begin : find_grant_index
            if (selected_grants[i]) grant_index = $clog2(N)'(i);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prio_mask <= '0;
        end else begin
            // if grant to 3 but not taken, and new requester 1 asserts, then we change output despite not having handshake
            // bump mask even when not taken
            if (grant_valid) 
                prio_mask <= (grant_taken) ? ~(selected_grants << 1) + 1 : (~selected_grants) + 1;
        end
    end

endmodule