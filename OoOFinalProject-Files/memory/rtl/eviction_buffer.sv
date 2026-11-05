// Eviction buffer
//STATUS: not implemeneted yet 

/*What it does: 
    - Used to store the evicted cache lines from the cache. 
    - Used to store the evicted cache lines until they are written back to the memory.
    - When L1 kicks a line out to make room, the line goes here first and then 
    on to L2. This lets L1 accept its new line right away instead of waiting
    for L2 to be free.
*/

// SIZE: EB_SIZE = 4 lines, fully associative (any line can go in any slot
/* TALKS TO
    - in  <- l1_cache   : every L1 victim, clean or dirty (line_pkd_t)
    - out -> l2_cache   : insert the line; L2 answers insert_done when stored
    - <-> mshr_file     : probe - if a missing line is here, send it back to L1
*/

module eviction_buffer;
endmodule
