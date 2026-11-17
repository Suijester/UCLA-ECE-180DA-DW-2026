import mem_pkg::*;

// abstract away RAM model
module mem_arbiter (
    input logic clk,
    input logic rst_n,

    // mshr data accesses
    input logic mem_req_valid,
    output logic mem_req_ready,
    input line_addr_t mem_req_line_addr,
    input mshr_id_t mem_req_mshr_id,

    output logic mem_resp_valid,
    output line_data_t mem_resp_data,
    output mshr_id_t mem_resp_mshr_id,

    // writeback data writes
    output logic arb_write_ready,
    input logic arb_write_valid,
    input line_pkd_t arb_write_line,
    output logic arb_write_done,

    // modport interface
    data_memory_if.client ram
);

    // in-flight request information
    arb_state arbiter_state;
    line_pkd_t req_write_line;
    line_addr_t req_line_addr;
    mshr_id_t req_mshr_id;
    line_data_t mem_data;

    assign mem_resp_mshr_id = req_mshr_id;
    assign mem_resp_data = mem_data;

    // 0 -> last served write, 1 -> last served read
    logic previously_served;

    // count number of words served & whether we've sent a word
    logic [$clog2(WORDS_PER_BLOCK)-1:0] request_words_served;
    logic word_sent;
    
    // interface with ram
    always_comb begin
        ram.request_valid = (arbiter_state != ARB_IDLE) && !word_sent;
        ram.write = (arbiter_state == SERVING_WRITE);
        ram.address = {req_line_addr, request_words_served, 2'b00};
        ram.write_data = req_write_line.data[(request_words_served * 32) +: 32];
        ram.byte_enable = '1;
        ram.response_ready = 1'b1;
    end

    // prevent starvation of either
    assign arb_write_ready = (arbiter_state == ARB_IDLE) && (previously_served || !mem_req_valid);
    assign mem_req_ready = (arbiter_state == ARB_IDLE) && (!previously_served || !arb_write_valid);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            arbiter_state <= ARB_IDLE;
            previously_served <= 1'b0;

            mem_resp_valid <= 1'b0;
            arb_write_done <= 1'b0;
        end else begin
            mem_resp_valid <= 1'b0;
            arb_write_done <= 1'b0;

            case (arbiter_state)
                ARB_IDLE: begin
                    if (arb_write_valid && arb_write_ready) begin
                        arbiter_state <= SERVING_WRITE;
                        req_write_line <= arb_write_line;
                        req_line_addr <= arb_write_line.line_addr;
                        previously_served <= 1'b0;

                        word_sent <= 1'b0;
                        request_words_served <= '0;
                    end

                    if (mem_req_valid && mem_req_ready) begin
                        arbiter_state <= SERVING_READ;
                        req_line_addr <= mem_req_line_addr;
                        req_mshr_id <= mem_req_mshr_id;
                        previously_served <= 1'b1;

                        word_sent <= 1'b0;
                        request_words_served <= '0;
                    end
                end

                SERVING_READ: begin
                    if (!word_sent && ram.request_ready) begin
                        word_sent <= 1'b1;
                    end else if (word_sent && ram.response_valid) begin
                        if (request_words_served == WORDS_PER_BLOCK-1) begin
                            arbiter_state <= ARB_IDLE;
                            mem_resp_valid <= 1'b1;
                        end else begin
                            request_words_served <= request_words_served + 1;
                            word_sent <= 1'b0;
                        end

                        mem_data[(request_words_served * 32) +: 32] <= ram.read_data;
                    end
                end

                SERVING_WRITE: begin
                    if (!word_sent && ram.request_ready) begin
                        word_sent <= 1'b1;
                    end else if (word_sent && ram.response_valid) begin
                        if (request_words_served == WORDS_PER_BLOCK-1) begin
                            arbiter_state <= ARB_IDLE;
                            arb_write_done <= 1'b1;
                        end else begin
                            request_words_served <= request_words_served + 1;
                            word_sent <= 1'b0;
                        end
                    end
                end

                // ensure this never happens
                default: arbiter_state <= ARB_IDLE;
            endcase
        end
    end

endmodule
