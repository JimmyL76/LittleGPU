`timescale 1ns / 1ps

import common_pkg::*;

module coalescer #(
    parameter int THREADS_PER_WARP = 32,
    parameter int MEM_LINE_BYTES = 128
    )(
    input logic clk, reset,
    
    // downstream - per-thread lsu mem-side ports, word-wide, unchanged from lsu
    input logic [THREADS_PER_WARP-1:0] lsu_valid,
    input data_mem_addr_t lsu_addr [THREADS_PER_WARP],
    input data_t lsu_data [THREADS_PER_WARP],
    input logic [(`DATA_WIDTH/8)-1:0] lsu_we [THREADS_PER_WARP],
    output logic [THREADS_PER_WARP-1:0] lsu_resp_valid,
    input logic [THREADS_PER_WARP-1:0] lsu_resp_ready,
    output data_t lsu_resp_data [THREADS_PER_WARP],
    
    // upstream - single mem_controller user port, line-wide
    output logic mem_valid,
    output data_mem_addr_t mem_addr,
    output logic [MEM_LINE_BYTES*8-1:0] mem_data,
    output logic [MEM_LINE_BYTES-1:0] mem_we,
    input logic mem_resp_valid,
    output logic mem_resp_ready,
    input logic [MEM_LINE_BYTES*8-1:0] mem_resp_data
    );

    // derived widths
    localparam int LINE_BITS = MEM_LINE_BYTES * 8;
    localparam int WORD_BYTES = `DATA_WIDTH / 8; // bytes per lsu word (4)
    localparam int WORDS_PER_LINE = MEM_LINE_BYTES / WORD_BYTES;
    // # of addr bits below line boundary (byte-in-line offset)
    localparam int LINE_BYTE_OFF_BITS = $clog2(MEM_LINE_BYTES);
    // # of addr bits to pick word slot inside line, min 1 to keep valid range
    localparam int WORD_SLOT_BITS = (WORDS_PER_LINE > 1) ? $clog2(WORDS_PER_LINE) : 1;
    
/* 
    ex: MEM_LINE_BYTES = 128, DATA_WIDTH = 32 (WORD_BYTES = 4)
                     <-  LINE_BYTE_OFF_BITS = $clog2(128) = 7  ->
                     <- WORD_SLOT_BITS = $clog2(32) = 5 -><- 2 ->
 +-------------------+----------------------------------+-------+
 |        row        |  word slot inside line           | byte  |
 |   bits [31:7]     |        bits [6:2]                | [1:0] |
 +-------------------+----------------------------------+-------+
       line_id              latched_word_off          byte-in-word
                                                       (handled by lsu)
*/
    
    // elab-time checks
    initial begin
        if (MEM_LINE_BYTES < WORD_BYTES)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be >= WORD_BYTES (%0d)", MEM_LINE_BYTES, WORD_BYTES);
        if (MEM_LINE_BYTES % WORD_BYTES != 0)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be multiple of WORD_BYTES (%0d)", MEM_LINE_BYTES, WORD_BYTES);
        if ((MEM_LINE_BYTES & (MEM_LINE_BYTES - 1)) != 0)
            $fatal(1, "coalescer: MEM_LINE_BYTES (%0d) must be power of 2", MEM_LINE_BYTES);
    end
    
    // line id = address with byte-in-line offset stripped
    typedef logic [`DATA_MEM_ADDR_WIDTH-LINE_BYTE_OFF_BITS-1:0] line_id_t;
    
    // per-thread latched state, captured at round start, held stable across groups
    line_id_t latched_line_id [THREADS_PER_WARP];
    data_mem_addr_t latched_addr [THREADS_PER_WARP];
    data_t latched_data [THREADS_PER_WARP];
    logic [WORD_BYTES-1:0] latched_we [THREADS_PER_WARP];
    // word slot inside line (which word position this thread occupies)
    logic [WORD_SLOT_BITS-1:0] latched_word_off [THREADS_PER_WARP];
    logic [THREADS_PER_WARP-1:0] pending; // 1 = thread still needs response
    
    // which threads bundled into current request
    logic [THREADS_PER_WARP-1:0] group_mask;
    
    typedef enum logic [1:0] {
        COAL_IDLE,    // waiting for any lsu_valid
        COAL_SEND,    // build group + drive request
        COAL_WAIT     // request held, waiting for mem_resp_valid
    } coal_state_t;
    coal_state_t s, next_s;
    
    // pick lowest pending thread as leader for next group
    // pending & (~pending + 1) isolates lowest set bit as one-hot
    // (same as dispatcher.sv's nth_free_core, just on set bits)
    logic [THREADS_PER_WARP-1:0] leader_onehot;
    assign leader_onehot = pending & (~pending + 1);
    
    // leader's line id and base addr via OR-reduction across one-hot mask
    // cheaper than priority-encoding to binary index then doing 32:1 mux
    line_id_t leader_line_id;
    data_mem_addr_t leader_addr;
    always_comb begin
        leader_line_id = '0;
        leader_addr = '0;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (leader_onehot[t]) begin
                leader_line_id = latched_line_id[t];
                leader_addr = latched_addr[t];
            end
        end
    end
    
    // group_mask = every pending thread whose latched line id matches leader's
    logic [THREADS_PER_WARP-1:0] next_group_mask;
    always_comb begin
        next_group_mask = '0;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (pending[t] && (latched_line_id[t] == leader_line_id))
                next_group_mask[t] = 1'b1;
        end
    end
    
    // build line-wide write payload by placing each grouped thread's word
    // at its own word slot in line, with byte-level we
    // conflicts have lowest thread index wins per byte
    logic [LINE_BITS-1:0] merged_wdata;
    logic [MEM_LINE_BYTES-1:0] merged_we;
    always_comb begin
        merged_wdata = '0;
        merged_we = '0;
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            if (next_group_mask[t]) begin
                // thread t's word lives at byte offset latched_word_off[t]*WORD_BYTES
                // for each byte b in its word, claim that byte if not already claimed
                for (int b = 0; b < WORD_BYTES; b++) begin
                    automatic int byte_pos = latched_word_off[t] * WORD_BYTES + b;
                    if (latched_we[t][b] && !merged_we[byte_pos]) begin
                        merged_we[byte_pos] = 1'b1;
                        merged_wdata[byte_pos*8 +: 8] = latched_data[t][b*8 +: 8];
                    end
                end
            end
        end
    end
    
    always_comb begin
        // defaults
        mem_valid = 1'b0;
        mem_addr = '0;
        mem_data = '0;
        mem_we = '0;
        mem_resp_ready = 1'b0;
        lsu_resp_valid = '0;
        // per-thread word slice
        for (int t = 0; t < THREADS_PER_WARP; t++) begin
            lsu_resp_data[t] = mem_resp_data[latched_word_off[t]*`DATA_WIDTH +: `DATA_WIDTH];
        end
        
        case (s)
            COAL_IDLE: begin
                next_s = (|lsu_valid) ? COAL_SEND : COAL_IDLE;
            end
            COAL_SEND: begin
                mem_valid = 1'b1;
                mem_addr = leader_addr;
                mem_data = merged_wdata;
                mem_we = merged_we;
                next_s = COAL_WAIT;
            end
            COAL_WAIT: begin
                mem_valid = 1'b1;
                mem_addr = leader_addr;
                mem_data = merged_wdata;
                mem_we = merged_we;
                // ready when every lsu in group is ready
                mem_resp_ready = ((lsu_resp_ready & group_mask) == group_mask);
                if (mem_resp_valid && mem_resp_ready) begin
                    // pulse valid only for threads in this group
                    lsu_resp_valid = group_mask;
                    // if any threads still pending after this group, go service next
                    next_s = ((pending & ~group_mask) != 0) ? COAL_SEND : COAL_IDLE;
                end else begin
                    next_s = COAL_WAIT;
                end
            end
            default: next_s = COAL_IDLE;
        endcase
    end
    
    // sequential - latch round state on entry, advance group on completion
    always_ff @(posedge clk or negedge reset) begin
        if (!reset) begin
            s <= COAL_IDLE;
            pending <= '0;
            group_mask <= '0;
            for (int t = 0; t < THREADS_PER_WARP; t++) begin
                latched_line_id[t] <= '0;
                latched_addr[t] <= '0;
                latched_data[t] <= '0;
                latched_we[t] <= '0;
                latched_word_off[t] <= '0;
            end
        end else begin
            s <= next_s;
            
            case (s)
                COAL_IDLE: begin
                    // entering new round, snapshot every active thread's request
                    if (|lsu_valid) begin
                        pending <= lsu_valid;
                        for (int t = 0; t < THREADS_PER_WARP; t++) begin
                            latched_addr[t] <= lsu_addr[t];
                            latched_data[t] <= lsu_data[t];
                            latched_we[t] <= lsu_we[t];
                            latched_line_id[t] <= lsu_addr[t][`DATA_MEM_ADDR_WIDTH-1:LINE_BYTE_OFF_BITS];
                            // word slot: addr bits between word boundary and line boundary
                            // degenerates to 0 when WORDS_PER_LINE == 1 (4-byte line)
                            if (WORDS_PER_LINE > 1)
                                latched_word_off[t] <= lsu_addr[t][LINE_BYTE_OFF_BITS-1:$clog2(WORD_BYTES)];
                            else
                                latched_word_off[t] <= '0;
                        end
                    end
                end
                COAL_SEND: begin
                    // capture group about to drive
                    group_mask <= next_group_mask;
                end
                COAL_WAIT: begin
                    if (mem_resp_valid && mem_resp_ready) begin
                        // clear serviced threads from pending
                        pending <= pending & ~group_mask;
                        $display("Coalescer: group serviced, mask=%b, remaining=%b", group_mask, pending & ~group_mask);
                    end
                end
                default: begin end
            endcase
        end
    end

endmodule
