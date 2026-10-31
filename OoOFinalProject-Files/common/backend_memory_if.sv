

interface backend_memory_if;

    // Import Packages
    import rv32_ooo_pkg::*;

    // Issue and Completion Handshakes, Plus LSU Busy Status
    // An issue or result transfers when its valid and ready are both high.
    logic issue_valid, issue_ready, busy, result_valid, result_ready;

    // From the Backend - instruction metadata and captured register values
    renamed_uop_t issue_uop;
    logic [XLEN-1:0] source_1, source_2;
    rob_tag_t rob_head_tag;

    // From the LSU - completion tag and optional load writeback
    execution_result_t result;


    // ----- Backend Side -----
    modport backend(
        output issue_valid,
               issue_uop,
               source_1,
               source_2,
               rob_head_tag,
               result_ready,

        input issue_ready,
              busy,
              result_valid,
              result
    );


    // ----- Memory / LSU Side -----
    modport memory(
        input issue_valid,
              issue_uop,
              source_1,
              source_2,
              rob_head_tag,
              result_ready,

        output issue_ready,
               busy,
               result_valid,
               result
    );

endinterface
