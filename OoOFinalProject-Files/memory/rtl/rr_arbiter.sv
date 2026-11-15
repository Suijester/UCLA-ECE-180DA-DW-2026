// standard rr arb using two fixed prio arb
module rr_arbiter (
    parameter N = 32
) (
    input logic clk,
    input logic rst_n,

    input logic [N-1:0] reqs,
    output logic [N-1:0] grants
);

    logic [N-1:0] prio_mask, prio_grant, grant;
    assign grants = (|prio_grant) ? prio_grant : grant;

    function automatic logic [N-1:0] fixed_prio_arb (input logic [N-1:0] reqs);
        return reqs & (~reqs + 1);
    endfunction

    assign grant = fixed_prio_arb(reqs);
    assign prio_grant = fixed_prio_arb(reqs & prio_mask);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            prio_mask <= '0;
        end else begin
            if (|grants) prio_mask <= ~(grants << 1) + 1;
        end
    end

endmodule