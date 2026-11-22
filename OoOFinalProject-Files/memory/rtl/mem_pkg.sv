package mem_pkg;
    import rv32_ooo_pkg::*;
    
    localparam L1_SIZE = 4096;
    localparam L1_WAYS = 4;

    // L2 cache parameters
    localparam L2_SIZE = 32768;
    localparam L2_WAYS = 8;

    localparam BLOCK_SIZE = 16;

    // individual structure size
    localparam LQ_SIZE = 8;
    localparam SQ_SIZE = 8;
    localparam MSHR_COUNT = 4;
    localparam EB_SIZE = 4;
    localparam WB_SIZE = 4;

    // store-set specific parameters
    localparam SSIT_SIZE = 128;
    localparam LFST_SIZE = 16;

    // derived parameters (do not modify directly)
    localparam OFFSET_BITS = $clog2(BLOCK_SIZE);
    localparam WORDS_PER_BLOCK = BLOCK_SIZE / 4;
    localparam WORD_SEL_BITS = $clog2(WORDS_PER_BLOCK);

    // cache parameters
    localparam L1_SETS = L1_SIZE / (L1_WAYS * BLOCK_SIZE);
    localparam L2_SETS = L2_SIZE / (L2_WAYS * BLOCK_SIZE);

    localparam L1_INDEX_BITS = $clog2(L1_SETS);
    localparam L2_INDEX_BITS = $clog2(L2_SETS);

    localparam L1_TAG_BITS = XLEN - L1_INDEX_BITS - OFFSET_BITS;
    localparam L2_TAG_BITS = XLEN - L2_INDEX_BITS - OFFSET_BITS;

    // pointer typedefs
    typedef logic [XLEN-OFFSET_BITS-1:0] line_addr_t;
    typedef logic [BLOCK_SIZE*8-1:0] line_data_t;

    typedef logic [$clog2(LQ_SIZE)-1:0] lq_idx_t;
    typedef logic [$clog2(SQ_SIZE)-1:0] st_idx_t;

    typedef logic [$clog2(LQ_SIZE):0] lq_ptr_t;
    typedef logic [$clog2(SQ_SIZE):0] st_ptr_t;

    typedef logic [$clog2(MSHR_COUNT)-1:0] mshr_id_t;
    typedef logic [$clog2(L1_WAYS)-1:0] l1_way_ptr_t;
    typedef logic [$clog2(L2_WAYS)-1:0] l2_way_ptr_t;

    typedef logic [$clog2(EB_SIZE)-1:0] eb_way_ptr_t;
    typedef logic [$clog2(WB_SIZE)-1:0] wb_way_ptr_t;
    
    // store set typedefs
    typedef logic [$clog2(SSIT_SIZE)-1:0] ssit_ptr_t; // SSIT indexing bits
    typedef logic [$clog2(LFST_SIZE)-1:0] ssit_t; // SSIT id indexing LFST

    // cache line standard packaging
    typedef struct packed {
        line_addr_t line_addr;
        line_data_t data;
        logic dirty;
        logic reuse;
    } line_pkd_t;

    // disambiguation parameterization
    typedef enum logic [1:0] {
        AGGRESSIVE_DISAMBIG,
        STORE_SET_DISAMBIG,
        CONSERVATIVE_DISAMBIG
    } disambig_type;

    // for each mshr, which memory it's accessing
    typedef enum logic [2:0] {
        EB_SNOOP,
        L2_SNOOP,
        L2_WAIT,
        WB_SNOOP,
        MEM_SNOOP,
        MEM_WAIT,
        FILL_WAIT
    } mshr_state;

    // state of l2 cache at any given time
    typedef enum logic [2:0] {
        IDLE,
        REQ_DATA,
        RESP,
        INS_SELECT,
        INS_EVICT,
        INS_WRITE
    } l2_state;

    typedef enum logic [1:0] {
        ARB_IDLE,
        SERVING_WRITE,
        SERVING_READ
    } arb_state;


    //load queue entry
    typedef struct packed {
        logic valid;
        rob_tag_t rob_tag;

        logic [XLEN-1:0] addr;
        logic addr_valid;
        logic [3:0] byte_mask;
        logic [1:0] byte_offset;
        logic load_unsigned;
        
        mem_size_e mem_size;
        logic executed;

        logic sq_checked; //sent request to sq?
        logic l1_waiting; //gotten response from l1?
        logic result_pending; //load_result calculated?

        logic [XLEN-1:0] result_data;
        logic [3:0] fwd_mask;
        logic [XLEN-1:0] fwd_data;

        st_ptr_t sq_tail_snapshot;

        logic wait_wake;
        logic wake_seen;
        logic l1_retry;

        phys_reg_t writeback_pdst;
        logic under_unresolved_branch;

    } lq_entry_t;
endpackage
    

