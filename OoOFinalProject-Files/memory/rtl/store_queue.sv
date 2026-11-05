// Store queue (retired entries at the head are the store buffer)
//STATUS: will start [Noosha]

/* WHAT IT DOES
   - A waiting room for stores.
   - A store may not change memory until the ROB
   retires it (it might be on a wrong branch path and get thrown away), so
   every store sits here from issue until it is safely written into L1.
   - The retired entries at the head of the queue act as the "store buffer".
*/

/* TALKS TO
   - in  <- address_gen     : word_addr, bytes_accessed (byte enables),
                            store_data (already copied into every byte lane)
   - in  <- backend          : rob_tag of the store; under_unresolved_branch bit
   - in  <- backend_memory_if: rob_head_tag (tells us when a store has retired)
   - in  <- branch resolve   : mispredict -> squash wrong-path stores
   - out -> load_result      : "this store is done" completion to the ROB
                            (writeback_valid = 0, stores have no register result)
   - out -> store_forward    : every entry's addr / byte_en / data, so loads can
                            take bytes from older stores
   - out -> l1_cache         : the oldest retired store, to be written (drained)
   - out -> memory_top       : full / free count, so issue can stall
*/

/* STATE PER ENTRY (see mem_pkg: SQ_SIZE = 8, st_idx_t, st_ptr_t)
   valid, rob_tag, word_addr, byte_en[3:0], data[31:0],
   resolved (addr+data captured), retired, under_branch,
   later (stage 3): set_id for store sets
/*

+// LIFECYCLE OF ONE ENTRY
   FREE -> ALLOCATED (tail++) -> RESOLVED (addr/data written, completion sent)
        -> RETIRED (ROB head moved past it) -> DRAINING (writing L1)
        -> FREE (head++ once L1 accepts the write)
*/

module store_queue;
endmodule
