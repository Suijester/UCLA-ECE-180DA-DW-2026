// Load result: extract/extend + completion queue
//STATUS: in progress [Jessie]


/* WHAT IT DOES
    - The last step before an answer goes back to the backend.
    - For a load: pick the needed byte(s) out of the 32-bit word and sign- or
    - zero-extend them. For loads AND stores: build the completion message.
*/

/* TALKS TO
    - in  <- store_forward : merged 32-bit word for a load
    - in  <- load_queue    : rob_tag, pdst, byte_offset, size, load_unsigned
    - in  <- store_queue   : "store resolved" -> needs a completion too
    - out -> backend       : be.result_valid / be.result (execution_result_t)
    - in  <- backend       : be.result_ready (backend can say "not now")
*/

module load_result;
endmodule
