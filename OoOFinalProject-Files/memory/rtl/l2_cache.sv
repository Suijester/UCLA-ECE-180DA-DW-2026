// L2 cache, exclusive, lockup-free (replacement policy inside)
//STATUS: in progress [Aki]

/*What it does: 
   - The bigger, slower cache below L1. It is EXCLUSIVE: a line lives in L1 
   or in L2, never both. (Spec 3.3 requires exclusive.)
*/

/* SIZE: 
    - L2_SIZE = 32 KB now (will parameterize in case we change later)
    - L2_WAYS = 8, BLOCK_SIZE = 16 B. Address = tag | index | offset[3:0].
*/

/* TALKS TO
    - in  <- eviction_buffer  : L1 victims to insert (the ONLY way lines arrive)
    - <-> mshr_file           : lookups; a hit sends the line up to L1
    - out -> writeback_buffer : dirty lines it evicts (clean ones are dropped)
*/

/* How Exclusive works:
    - When L1 evicts a line, it goes to L2. If L2 has the line, it is replaced.
    - When L1 looks up a line, if it is not in L1, it looks in L2. If it is in L2,
      it is sent up to L1 and removed from L2. (This is how exclusivity is maintained.)
*/

/* REPLACEMENT: RRIP (group 1's assigned policy, spec 3.4)
    - L2 hit   -> line moves to L1 and is REMOVED from L2.
    - L1 evict -> line goes down to L2 (through the eviction buffer).
    - RAM fill -> goes straight to L1, never into L2.
    - So L2 never waits on RAM and needs no MSHRs of its own.
*/

module l2_cache;
endmodule
