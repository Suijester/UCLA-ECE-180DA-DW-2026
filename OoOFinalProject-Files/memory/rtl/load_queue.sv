// Load queue
//STATUS: in progress [Jessie]

/*What it does?: 
    - Keeps track of every load in flight: its address, whether it has run yet,
    and whether it must wait. 
    - Loads can be cancelled (wrong branch path) or, in later stages, found to have read stale data and need a redo.
*/

//SIZE: LQ_SIZE = 8

/* TALKS TO
    - in  <- address_gen  : word_addr, byte_offset, bytes_accessed
    - in  <- backend      : rob_tag, pdst (destination register), load_unsigned, under_unresolved_branch
    - in  <- store_queue  : are all OLDER stores' addresses known? (CONSERVATIVE)
    - out -> l1_cache     : the load picked to read L1 this cycle
    - out -> mshr_file    : on a miss, the load waits for the MSHR to wake it
    - out -> load_result  : rob_tag / pdst / size info for the final answer
*/

/* HOW IT WORKS
    1. Load gets an entry (at issue now, at dispatch in stage 3).
    2. When the disambiguation mode allows, it reads L1 and searches the SQ
        for older stores in the same cycle.
    3. Hit -> answer in 2 cycles. Miss -> waits on an MSHR; L1 keeps serving
       other loads meanwhile.
*/


module load_queue;
endmodule
