// Forward & merge
//STATUS: will start [Noosha]

/*WHAT IT DOES
    - A load might read an address that an OLDER store wrote but has not yet
    put into L1 (it is still in the store queue). 
    - This block builds thecorrect 4-byte word for the load, one byte at a time.
*/

/*TALKS TO
    - in  <- load_queue   : the load's word_addr, bytes_accessed, its age
    - in  <- store_queue  : every entry's word_addr, byte_en, data, valid/age
    - in  <- l1_cache     : the word read from L1 (on a hit)
    - in  <- mshr_file    : the word that just arrived from L2/RAM (on a miss)
    - out -> load_result  : the merged 32-bit word
*/ 

/* HOW IT WORKS (per byte, 4 times in parallel)
    - For byte i of the word:
        look at stores that are OLDER than the load, same word_addr,
        and whose byte_en[i] is 1  ->  take the YOUNGEST of those.
        If no such store, take byte i from L1 (or the MSHR).
*/

module store_forward;
endmodule
