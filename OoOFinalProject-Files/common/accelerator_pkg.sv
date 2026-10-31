// Custom CSR addresses used by the CSR unit and accelerator software.


package accelerator_pkg;

    // ----- Accelerator Configuration Registers -----
    // Three writable CSRs. This core does not implement privilege modes.
    localparam logic [11:0] CSR_ACC_ACTIVATE = 12'h7c0;
    localparam logic [11:0] CSR_ACC_MEMORY_LOCATION = 12'h7c1;
    localparam logic [11:0] CSR_ACC_LENGTH = 12'h7c2;

    // ACTIVATE Status Bits
    // Bit 0: requested/running. Hardware clears it when the job finishes.
    // Bit 1: sticky completion error, recorded by hardware and read-only to software.
    // An idle write uses bit 0 and clears error; other written bits are ignored.
       // -----------------------------------------------------------------------
    // Network geometry
    //
    //   28x28x1  --conv1 5x5x1 x3--> 24x24x3 --pool 2x2--> 12x12x3
    //            --conv2 5x5x3 x3-->  8x 8x3 --pool 2x2-->  4x 4x3
    //            --flatten--> 48 --fc 10x48--> 10 logits --argmax--> digit
    //
    // Both convolutions are stride 1 with NO padding ("valid"), which is why
    // 28 -> 24 and 12 -> 8.
    // -----------------------------------------------------------------------
    localparam int unsigned IMG_H  = 28, IMG_W  = 28, IMG_C = 1;
    localparam int unsigned C1_K   = 5,  C1_OC  = 3;
    localparam int unsigned A1_H   = 24, A1_W   = 24;
    localparam int unsigned P1_H   = 12, P1_W   = 12;
    localparam int unsigned C2_K   = 5,  C2_OC  = 3;
    localparam int unsigned A2_H   = 8,  A2_W   = 8;
    localparam int unsigned P2_H   = 4,  P2_W   = 4;
    localparam int unsigned FLAT   = P2_H * P2_W * C2_OC;   // 48
    localparam int unsigned FC_O   = 10;

    // Element counts
    localparam int unsigned IMG_PIXELS = IMG_H * IMG_W;              //  784
    localparam int unsigned A1_ELEMS   = A1_H * A1_W * C1_OC;        // 1728
    localparam int unsigned P1_ELEMS   = P1_H * P1_W * C1_OC;        //  432
    localparam int unsigned A2_ELEMS   = A2_H * A2_W * C2_OC;        //  192
    localparam int unsigned P2_ELEMS   = P2_H * P2_W * C2_OC;        //   48

    // Weight counts
    localparam int unsigned C1_W_COUNT = C1_OC * C1_K * C1_K;         //  75
    localparam int unsigned C2_W_COUNT = C2_OC * C2_K * C2_K * C1_OC; // 225
    localparam int unsigned FC_W_COUNT = FC_O * FLAT;                 // 480

    // Total multiply-accumulates for one inference. Useful for sizing your
    // design: at one MAC per cycle this is your cycle count.
    //   conv1 24*24*3*25     = 43200
    //   conv2  8* 8*3*75     = 14400
    //   fc       10*48       =   480
    localparam int unsigned TOTAL_MACS = 58080;

    // -----------------------------------------------------------------------
    // Local memory sizes
    // -----------------------------------------------------------------------
    localparam int unsigned IMG_MEM_BYTES = 2048;   // two 1024-byte image slots
    localparam int unsigned WGT_MEM_BYTES = 1024;
    localparam int unsigned ACT_A_BYTES   = 2048;   // holds conv1 out (1728)
    localparam int unsigned ACT_B_BYTES   = 512;    // holds pool1 out (432)
    localparam int unsigned PARAM_WORDS   = 32;
    localparam int unsigned RES_WORDS     = 16;

    localparam int unsigned IMG_ADDR_W   = $clog2(IMG_MEM_BYTES);   // 11
    localparam int unsigned WGT_ADDR_W   = $clog2(WGT_MEM_BYTES);   // 10
    localparam int unsigned ACT_A_ADDR_W = $clog2(ACT_A_BYTES);     // 11
    localparam int unsigned ACT_B_ADDR_W = $clog2(ACT_B_BYTES);     // 9
    localparam int unsigned PARAM_ADDR_W = $clog2(PARAM_WORDS);     // 5
    localparam int unsigned RES_ADDR_W   = $clog2(RES_WORDS);       // 4

    // -----------------------------------------------------------------------
    // Weight memory layout -- byte offsets
    // -----------------------------------------------------------------------
    localparam int unsigned WGT_CONV1_BASE = 'h000;   //  75 bytes
    localparam int unsigned WGT_CONV2_BASE = 'h080;   // 225 bytes
    localparam int unsigned WGT_FC_BASE    = 'h180;   // 480 bytes, ends at 'h360

    // -----------------------------------------------------------------------
    // Parameter memory layout -- 32-bit word indices
    // -----------------------------------------------------------------------
    localparam int unsigned PAR_MAGIC    = 0;
    localparam int unsigned PAR_VERSION  = 1;
    localparam int unsigned PAR_SHIFT1   = 2;
    localparam int unsigned PAR_SHIFT2   = 3;
    localparam int unsigned PAR_CONV1_B  = 4;    // 3 words
    localparam int unsigned PAR_CONV2_B  = 7;    // 3 words
    localparam int unsigned PAR_FC_B     = 10;   // 10 words, ends at 19

    // -----------------------------------------------------------------------
    // Result memory layout -- 32-bit word indices
    // -----------------------------------------------------------------------
    localparam int unsigned RES_LOGIT  = 0;    // 10 words, signed int32
    localparam int unsigned RES_ARGMAX = 10;   // predicted digit, 0..9
    localparam int unsigned RES_MAGIC  = 11;   // write MAGIC when the job is done

    localparam logic [31:0] MAGIC   = 32'h434E_4E01;   // "CNN\x01"
    localparam logic [31:0] VERSION = 32'd1;

    // -----------------------------------------------------------------------
    // Types
    // -----------------------------------------------------------------------
    typedef logic        [7:0] act_t;    // activation / pixel, UNSIGNED 0..255
    typedef logic signed [7:0] wgt_t;    // weight,             SIGNED -128..127
    typedef logic signed [31:0] acc_t;   // accumulator and bias

    // Which internal memory a preload access targets.
    typedef enum logic [2:0] {
        MEM_IMG   = 3'd0,
        MEM_WGT   = 3'd1,
        MEM_PARAM = 3'd2,
        MEM_RES   = 3'd3,
        MEM_ACT_A = 3'd4,   // debug visibility only
        MEM_ACT_B = 3'd5
    } mem_sel_e;


endpackage
